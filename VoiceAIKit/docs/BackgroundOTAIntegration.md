# Mobile OTA NLU Update - Integration Guide

> [!IMPORTANT]
> **Host Application Responsibility**
> The `VoiceAIKit` SDK is completely agnostic to networking and background task scheduling. It is strictly the responsibility of the Host Application to communicate with the backend API, download the OTA `.nlu` zip payload, and schedule background tasks using `BGTaskScheduler`. 
> 
> The example code provided in `ExampleOTAManager.swift` is **reference application code only** and is not compiled into the SDK. You are free to adapt it using your preferred networking framework (e.g., Alamofire, URLSession).

## 1. Backend API Contract (BFF)

The OTA backend acts as a Backend-For-Frontend (BFF) proxy that parses GitHub Releases and provides a stable API.

### Check for Latest Update
**Endpoint:** `GET /api/v1/nlu/latest`

Checks if a newer NLU pack is available relative to the app's current version.

**Query Parameters:**
- `lang` (Optional, Default: "en"): Target language code.
- `platform` (Optional, Default: "universal"): Target platform.
- `current_pack_version` (Optional, Default: "1.0.0"): The semantic version of the current active NLU pack on the device.

**Success Response (HTTP 200):**
```json
{
  "update_available": true,
  "version": "1.0.36",
  "language": "en",
  "published_at": "2026-08-08T12:10:37Z",
  "download_url": "https://<server_domain>/api/v1/nlu/download?asset_id=506349416",
  "size_bytes": 2829387,
  "release_notes": "Single-language `.nlu` (spec/bundle/3.0)...",
  "sha256_hash": "hash-not-provided"
}
```
*(Note: Cryptographic integrity is verified via Ed25519 signatures inside the `.nlu` bundle itself by `VoiceAIKit`, so `sha256_hash` may be omitted).*

### Download the NLU Pack
**Endpoint:** `GET /api/v1/nlu/download`

**Query Parameters:**
- `asset_id` (Required): ID provided by the `/latest` endpoint.

**Response:**
Returns an **HTTP 302 Found** redirect to a signed AWS S3 / GitHub Object Storage URL. The Host Application's HTTP client must automatically follow redirects to stream the binary `.zip`.

---

## 2. Integration Workflow

The Host Application should implement the following flow (see `ExampleOTAManager.swift` for the code implementation):

### A. Polling
On app launch or via a background task (`BGAppRefreshTask`), hit the `/latest` endpoint. Pass the current active version so the server can evaluate `update_available`.

### B. Downloading
If an update is available and the network conditions are appropriate (e.g., WiFi, based on `size_bytes`), download the file using `URLSessionDownloadTask` to a temporary filesystem URL.

### C. Preparation
Pass the local temporary URL to the SDK:
```swift
try await voiceClient.installer.preparePack(from: tempZipURL, language: "en")
```
This extracts the zip, parses the manifest, checks iOS compatibility, and verifies the Ed25519 signatures.

### D. Activation Timing
> [!WARNING]
> Package download and preparation may occur at any time, but **activation should only occur when the inference engine is idle.** Activation must never interrupt an active inference session (e.g., while the user is speaking).

The Host App should wait for the engine to be idle before activating:
```swift
while !voiceClient.engineProvider.isIdle {
    try await Task.sleep(nanoseconds: 1_000_000_000)
}
try await voiceClient.installer.activatePreparedPack(language: "en")
```

### E. Retry Policy
Different applications have different retry strategies depending on battery constraints or connectivity. Therefore, **retry behavior is intentionally left to the Host Application.** You may choose to retry immediately, during the next background refresh, or on the next application launch if preparation or activation fails.
