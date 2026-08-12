import Foundation
import OSLog
import VoiceIntentKit

// Define the response from the BFF API
fileprivate struct NLUUpdateResponse: Codable {
    let updateAvailable: Bool
    let version: String?
    let downloadUrl: String?
    let sizeBytes: Int?

    enum CodingKeys: String, CodingKey {
        case updateAvailable = "update_available"
        case version
        case downloadUrl = "download_url"
        case sizeBytes = "size_bytes"
    }
}

public enum OTAUpdateError: LocalizedError {
    case invalidHTTPResponse(Int)
    case downloadFailed
    case sizeMismatch(expected: Int, got: Int)
    case invalidMetadata
    case cancelled
    case engineBusy
    case sdk(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse(let code): return "Server returned non-200 HTTP response: \(code)"
        case .downloadFailed: return "Download failed with non-200 status code"
        case .sizeMismatch(let expected, let got): return "Downloaded payload size (\(got) bytes) does not match the advertised size (\(expected) bytes)."
        case .invalidMetadata: return "Invalid metadata in response"
        case .cancelled: return "OTA Update cancelled by the system"
        case .engineBusy: return "Engine never became idle. OTA activation aborted."
        case .sdk(let error): return "SDK Error: \(error.localizedDescription)"
        }
    }
}

public enum OTAUpdateResult {
    case noUpdate
    case updated(version: String)
    case alreadyRunning
    case failed(OTAUpdateError)
}

// MARK: - BFF client

/// The outcome of polling the BFF `/latest` endpoint.
enum BFFLatest {
    /// No newer pack than the caller's current version.
    case upToDate
    /// A newer pack is offered.
    case available(version: String?, downloadURL: URL, sizeBytes: Int?)
}

/// Owns the network conversation with the OTA backend-for-frontend: polling `/latest`, decoding its
/// metadata, and downloading the payload with HTTP-status and byte-size checks.
///
/// It knows nothing about validation, storage, or activation. That separation (SRP) keeps
/// `NLUOTAManager` a pure orchestrator and lets tests inject a stubbed `URLSession` to exercise the
/// polling/decoding/size-check logic without a live server.
struct BFFUpdateClient {
    private let apiBaseURL: URL
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.starkey.stt", category: "OTA.BFF")

    init(apiBaseURL: URL, urlSession: URLSession) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
    }

    /// Polls `/latest` and decides whether an update newer than `currentVersion` is on offer.
    /// - Throws: `OTAUpdateError.invalidHTTPResponse` / `.invalidMetadata` on a bad response.
    func fetchLatest(language: String, currentVersion: String) async throws -> BFFLatest {
        let apiURL = apiBaseURL
            .appendingPathComponent("latest")
            .appending(queryItems: [
                URLQueryItem(name: "lang", value: language),
                URLQueryItem(name: "app_version", value: currentVersion), // dynamically injected from SDK
                URLQueryItem(name: "platform", value: "ios")
            ])

        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")

        logger.info("Making API Request to: \(apiURL.absoluteString)")
        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.error("BFF Server returned non-200 response. Exiting gracefully.")
            throw OTAUpdateError.invalidHTTPResponse(code)
        }

        let decoded: NLUUpdateResponse
        do {
            decoded = try JSONDecoder().decode(NLUUpdateResponse.self, from: data)
        } catch {
            logger.error("Failed to parse API metadata")
            throw OTAUpdateError.invalidMetadata
        }

        guard decoded.updateAvailable,
              let downloadString = decoded.downloadUrl,
              let downloadURL = URL(string: downloadString) else {
            return .upToDate
        }

        // Defensive check: the backend isn't accidentally serving the version we already have.
        if decoded.version == currentVersion {
            logger.info("Backend advertised the exact version we already have (\(currentVersion)). Ignoring.")
            return .upToDate
        }

        return .available(version: decoded.version, downloadURL: downloadURL, sizeBytes: decoded.sizeBytes)
    }

    /// Downloads the payload to a temporary URL, verifying the HTTP status and — if the BFF
    /// advertised one — the exact byte size. The caller owns cleanup of the returned temp file.
    /// - Throws: `OTAUpdateError.downloadFailed` / `.sizeMismatch`.
    func download(from url: URL, expectedSize: Int?) async throws -> URL {
        let (tempURL, response) = try await urlSession.download(from: url)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            logger.error("Download failed with non-200 status code.")
            throw OTAUpdateError.downloadFailed
        }

        // Size check is a hard fail. A mismatch means the payload is not what the BFF advertised — a
        // truncated download, a wrong asset, or tampering. Full Ed25519 + sha256 verification still
        // runs later in preparePack, but there is no reason to spend that work on a wrong-size blob.
        let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        if let size = attributes[.size] as? Int, let expected = expectedSize, size != expected {
            logger.error("Download size mismatch. Expected: \(expected), Got: \(size). Aborting.")
            throw OTAUpdateError.sizeMismatch(expected: expected, got: size)
        }

        return tempURL
    }
}

// MARK: - Orchestrator

/// The OTA orchestrator for the Host Application.
/// Implemented as an `actor` to guarantee idempotency and prevent concurrent downloads.
///
/// It coordinates but does not implement the individual steps: `BFFUpdateClient` does the network,
/// `VoiceIntentKit`'s installer does validation/activation. This file's only job is sequencing and
/// idempotency.
public actor NLUOTAManager {

    private let voiceClient: VoiceIntentClient
    private let bff: BFFUpdateClient

    // Modern Telemetry logger
    private let logger = Logger(subsystem: "com.starkey.stt", category: "OTA")

    // Track if an update is already in progress to prevent duplicate overlapping tasks
    private var isUpdateInProgress = false

    /// Initializes the OTA Manager.
    /// - Parameters:
    ///   - voiceClient: The shared VoiceIntentClient instance for the app.
    ///   - apiBaseURL: The base URL for the backend BFF API (e.g., `https://api.starkey.com/api/v1/nlu`).
    ///   - urlSession: Optional URLSession for dependency injection (useful for mocking in unit tests).
    public init(voiceClient: VoiceIntentClient, apiBaseURL: URL, urlSession: URLSession? = nil) {
        self.voiceClient = voiceClient

        let session: URLSession
        if let injectedSession = urlSession {
            session = injectedSession
        } else {
            let config = URLSessionConfiguration.default
            // URLSession follows standard HTTP redirects by default.
            // The backend may redirect downloads to object storage (GitHub, S3, etc.).
            config.urlCache = nil
            // Prevent hanging downloads
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 300
            session = URLSession(configuration: config)
        }
        self.bff = BFFUpdateClient(apiBaseURL: apiBaseURL, urlSession: session)
    }

    /// Fetches the currently active model version for UI display.
    public func getActivePackVersion(language: String) -> String {
        return voiceClient.activePackVersion(for: language) ?? "0.0.0"
    }

    /// Checks for a new OTA package, downloads it, and safely activates it.
    /// - Parameter language: The language code to check for (e.g., "en").
    @discardableResult
    public func checkForUpdates(language: String = "en") async -> OTAUpdateResult {
        guard !isUpdateInProgress else {
            logger.debug("OTA Update already in progress. Ignoring duplicate request.")
            return .alreadyRunning
        }

        isUpdateInProgress = true
        defer { isUpdateInProgress = false }

        logger.info("OTA Background update started for language: \(language)")
        let totalClock = ContinuousClock()
        let totalStart = totalClock.now

        let currentPackVersion = voiceClient.activePackVersion(for: language) ?? "0.0.0"

        // Ensure the temporary downloaded zip is always cleaned up.
        var tempZipURLToClean: URL? = nil
        defer {
            if let url = tempZipURLToClean {
                try? FileManager.default.removeItem(at: url)
            }
        }

        do {
            // 1. Poll the BFF.
            let latest = try await bff.fetchLatest(language: language, currentVersion: currentPackVersion)
            guard case let .available(version, downloadURL, sizeBytes) = latest else {
                logger.info("No OTA update available. Device is up to date.")
                return .noUpdate
            }
            logger.info("OTA Update available: Version \(version ?? "Unknown")")

            // 2. Download the payload (HTTP status + size verified inside).
            logger.info("Download started.")
            let tempZipURL = try await bff.download(from: downloadURL, expectedSize: sizeBytes)
            tempZipURLToClean = tempZipURL

            // 3. Handoff to VoiceIntentKit — extract, verify (Ed25519 + sha256), stage.
            let manifest = try await voiceClient.installer.preparePack(from: tempZipURL, language: language)
            logger.info("Package validation completed. Prepared version: \(manifest.version)")

            // 4. Activation safety — wait for the inference engine to be idle.
            logger.info("Waiting for inference engine to become idle...")
            let clock = ContinuousClock()
            let timeout: Duration = .seconds(300) // 5 minutes max wait
            let start = clock.now
            while !voiceClient.isEngineIdle {
                if clock.now - start > timeout {
                    logger.error("Engine never became idle. Aborting activation.")
                    return .failed(.engineBusy)
                }
                try Task.checkCancellation() // Support cancellation if the background task runs out of time
                try await clock.sleep(for: .seconds(1))
            }

            // 5. Safe activation — real smoke test + atomic swap happen inside.
            try await voiceClient.installer.activatePreparedPack(language: language)

            let totalElapsed = totalClock.now - totalStart
            logger.info("Total OTA update completed in \(totalElapsed).")

            return .updated(version: version ?? manifest.version)

        } catch {
            if error is CancellationError {
                logger.info("OTA Update cancelled by the system (Background task expired).")
                return .failed(.cancelled)
            } else if let otaError = error as? OTAUpdateError {
                logger.error("OTA Update failed: \(otaError.localizedDescription)")
                return .failed(otaError)
            } else {
                logger.error("OTA Update failed due to SDK error: \(error.localizedDescription)")
                return .failed(.sdk(error))
            }
        }
    }
}
