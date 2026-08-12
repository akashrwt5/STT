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

/// The OTA orchestrator for the Host Application.
/// Implemented as an `actor` to guarantee idempotency and prevent concurrent downloads.
public actor NLUOTAManager {
    
    private let voiceClient: VoiceIntentClient
    private let apiBaseURL: URL
    private let urlSession: URLSession
    
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
        self.apiBaseURL = apiBaseURL
        
        if let injectedSession = urlSession {
            self.urlSession = injectedSession
        } else {
            let config = URLSessionConfiguration.default
            // URLSession follows standard HTTP redirects by default.
            // The backend may redirect downloads to object storage (GitHub, S3, etc.).
            config.urlCache = nil
            // Prevent hanging downloads
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 300
            self.urlSession = URLSession(configuration: config)
        }
    }
    
    /// Fetches the currently active model version for UI display.
    public func getActivePackVersion(language: String) -> String {
        return voiceClient.activePackVersion(for: language) ?? "0.0.0"
    }
    
    /// Checks for a new OTA package, downloads it, and safely activates it.
    /// - Parameters:
    ///   - language: The language code to check for (e.g., "en").
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
        
        // 1. Polling the BFF
        let currentPackVersion = voiceClient.activePackVersion(for: language) ?? "0.0.0"
        let apiURL = apiBaseURL
            .appendingPathComponent("latest")
            .appending(queryItems: [
                URLQueryItem(name: "lang", value: language),
                URLQueryItem(name: "app_version", value: currentPackVersion), // dynamically injected from SDK
                URLQueryItem(name: "platform", value: "ios")
            ])
        
        // Ensure temporary downloaded zip is always cleaned up
        var tempZipURLToClean: URL? = nil
        defer {
            if let url = tempZipURLToClean {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    // Suppress noise
                }
            }
        }
        
        do {
            let checkClock = ContinuousClock()
            let checkStart = checkClock.now
            
            var request = URLRequest(url: apiURL)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "accept")
            request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
            
            logger.info("Making API Request to: \(apiURL.absoluteString)")
            
            let (data, response) = try await urlSession.data(for: request)
            let checkElapsed = checkClock.now - checkStart
            logger.info("Update check completed in \(checkElapsed)")
            
            // Graceful Network Handling for 5xx errors
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                logger.error("BFF Server returned non-200 response. Exiting gracefully.")
                return .failed(.invalidHTTPResponse(code))
            }
            
            let updateResponse: NLUUpdateResponse
            do {
                updateResponse = try JSONDecoder().decode(NLUUpdateResponse.self, from: data)
            } catch {
                logger.error("Failed to parse API metadata")
                return .failed(.invalidMetadata)
            }
            
            // 2. Evaluate update availability
            guard updateResponse.updateAvailable,
                  let downloadString = updateResponse.downloadUrl,
                  let downloadURL = URL(string: downloadString) else {
                logger.info("No OTA update available. Device is up to date.")
                return .noUpdate
            }
            
            // Defensive Check: Ensure the backend isn't accidentally serving the version we already have
            if updateResponse.version == currentPackVersion {
                logger.info("Backend advertised the exact version we already have (\(currentPackVersion)). Ignoring.")
                return .noUpdate
            }
            
            logger.info("OTA Update available: Version \(updateResponse.version ?? "Unknown")")
            
            // 3. Downloading the Payload
            logger.info("Download started.")
            let downloadClock = ContinuousClock()
            let downloadStart = downloadClock.now
            let (tempZipURL, downloadResponse) = try await urlSession.download(from: downloadURL)
            let downloadElapsed = downloadClock.now - downloadStart
            logger.info("Download completed in \(downloadElapsed)")
            
            tempZipURLToClean = tempZipURL
            
            guard let downloadHTTPResponse = downloadResponse as? HTTPURLResponse, (200...299).contains(downloadHTTPResponse.statusCode) else {
                logger.error("Download failed with non-200 status code.")
                return .failed(.downloadFailed)
            }
            
            // Verify file size before extraction (hard fail). A size mismatch means the payload is
            // not what the BFF advertised — a truncated download, a wrong asset, or tampering. We do
            // NOT proceed and "rely on crypto later": fail fast and cheaply here. (Full Ed25519 +
            // sha256 verification still runs in preparePack regardless.)
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempZipURL.path)
            if let fileSize = fileAttributes[.size] as? Int, let expectedSize = updateResponse.sizeBytes,
               fileSize != expectedSize {
                logger.error("Download size mismatch. Expected: \(expectedSize), Got: \(fileSize). Aborting.")
                return .failed(.sizeMismatch(expected: expectedSize, got: fileSize))
            }
            
            // 4. Handoff to VoiceIntentKit
            let valClock = ContinuousClock()
            let valStart = valClock.now
            let manifest = try await voiceClient.installer.preparePack(from: tempZipURL, language: language)
            let valElapsed = valClock.now - valStart
            logger.info("Package validation completed in \(valElapsed). Prepared version: \(manifest.version)")
            
            // 5. Activation Safety (Wait for idle)
            logger.info("Activation started. Waiting for inference engine to become idle...")
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
            
            // 6. Safe Activation
            let actClock = ContinuousClock()
            let actStart = actClock.now
            try await voiceClient.installer.activatePreparedPack(language: language)
            let actElapsed = actClock.now - actStart
            logger.info("Activation completed successfully in \(actElapsed).")
            
            let totalElapsed = totalClock.now - totalStart
            logger.info("Total OTA update completed in \(totalElapsed).")
            
            let finalVersion = updateResponse.version ?? manifest.version
            return .updated(version: finalVersion)
            
        } catch {
            if error is CancellationError {
                logger.info("OTA Update cancelled by the system (Background task expired).")
                return .failed(.cancelled)
            } else if let otaError = error as? OTAUpdateError {
                logger.error("OTA Update failed.")
                return .failed(otaError)
            } else {
                logger.error("OTA Update failed due to SDK error: \(error.localizedDescription)")
                return .failed(.sdk(error))
            }
        }
    }
}
