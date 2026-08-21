# VoiceAIKit Technical Debt & TODOs

## Security
- [ ] **Enforce Ed25519 Cryptographic Signatures** (Target: v1.1 or v2.0)
  - **Context:** During the MVP phase, we made `trustedPublicKeyBase64` optional to unblock development and simplify the initial release. Currently, the SDK only validates SHA256 checksums (integrity) but skips signature verification (authenticity) if the public key is omitted.
  - **Action Item:** Make `trustedPublicKeyBase64` mandatory in `PackValidator`. Inject the official production public key from the backend to ensure malicious OTA payloads intercepted via MITM attacks are rejected.

## Network Optimization
- [ ] **Validate SDK Compatibility on Backend** (Target: v1.1)
  - **Action Item:** Once the backend supports it, update the Host App's API request to pass `&sdk_version=1.0.0` in the query parameters.

## Host Application Refinements (Phase 8 Polish)
- [ ] **Eliminate Magic Values in API Requests**
  - **Context:** The `NLUOTAManager` currently falls back to sending `current_pack_version=0.0.0` if no active pack exists. Magic strings are an anti-pattern.
  - **Action Item:** Refactor the API URL construction. Only append the `current_pack_version` query item if `voiceClient.activePackVersion()` returns a non-nil value. The backend should interpret the omission of this parameter as a request for the absolute latest package.
- [ ] **Extract Magic Strings into Constants**
  - **Context:** The platform identifier `"ios"` is hardcoded in the query parameters.
  - **Action Item:** Create a `private enum APIConstants { static let platform = "ios" }` inside `NLUOTAManager` and reference it to improve long-term maintainability.
- [ ] **Enforce SDK as the Absolute Source of Truth**
  - **Context:** `checkForUpdates()` currently returns `updateResponse.version ?? manifest.version`. Since the SDK validates the downloaded package, the SDK's parsed manifest is the ultimate authority on what was actually installed.
  - **Action Item:** Change the return statement to strictly `return .updated(version: manifest.version)` to prevent any edge cases where backend metadata falls out of sync with the physical artifact.
