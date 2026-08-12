import Foundation
import OSLog

/// Defines the protocol for the Host Application to provide the active inference engine.
/// Used to run a smoke test before a model is permanently activated.
public protocol NLUEngineProvider {
    /// Attempts to initialize the engine and run a lightweight smoke test.
    /// Should throw an error if the model is corrupted or incompatible.
    func smokeTest(modelPath: URL, vocabularyPath: URL) throws
    
    /// Fully loads the model into memory and prepares it for live voice sessions.
    func load(modelPath: URL, vocabularyPath: URL) throws
    
    /// Returns true if the engine is not currently processing audio or holding inference locks.
    var isIdle: Bool { get }
}

public enum InstallerError: Error, LocalizedError {
    case activationFailedEngineNotIdle
    case smokeTestFailed(Error)
    case filesystemActivationFailed(Error)
    case invalidStateForActivation
    
    public var errorDescription: String? {
        switch self {
        case .activationFailedEngineNotIdle:
            return "Activation failed because the NLU engine is currently active processing voice input."
        case .smokeTestFailed(let error):
            return "The downloaded model failed the safety smoke test: \(error.localizedDescription)"
        case .filesystemActivationFailed(let error):
            return "Failed to commit the active package to disk: \(error.localizedDescription)"
        case .invalidStateForActivation:
            return "Attempted to activate a pack that is not in the readyToActivate state."
        }
    }
}

/// The main orchestration class for NLU over-the-air updates.
/// The Host Application uses this to prepare downloaded zips and activate them when safe.
///
/// Thread safety: the mutable state (`preparedManifest`, `stagingState`) is guarded by the
/// internal `stateLock` below — NOT by an assumption that some upstream actor serializes callers.
/// `preparePack`/`activatePreparedPack` do no `await` inside the critical section, so holding the
/// lock across each call is safe and cannot deadlock.
public final class NLUPackInstaller: @unchecked Sendable {

    private let storage: PackStorageControlling
    private let validator: PackValidating
    private let engineProvider: NLUEngineProvider

    private let logger = Logger(subsystem: "com.starkey.voiceintentkit", category: "OTAInstaller")

    /// Serializes access to `preparedManifest` and `stagingState`.
    private let stateLock = NSLock()

    /// The parsed manifest from the most recent prepare operation.
    private var preparedManifest: NLUPackManifest?

    /// Tracks the state of the pack currently sitting in the staging directory.
    private var _stagingState: PackState = .downloaded

    /// The state of the pack currently sitting in the staging directory. Thread-safe.
    public var stagingState: PackState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _stagingState
    }
    
    public init(storage: PackStorageControlling, validator: PackValidating, engineProvider: NLUEngineProvider) {
        self.storage = storage
        self.validator = validator
        self.engineProvider = engineProvider
    }
    
    /// Prepares a downloaded `.nlu` zip file for installation.
    /// This extracts the package into a temporary staging area and validates its cryptographic integrity.
    /// - Parameters:
    ///   - packageURL: The local URL where the Host App saved the downloaded `.zip` or `.nlu` file.
    ///   - language: The language code this pack targets (e.g., "en").
    /// - Returns: The parsed manifest, so the Host App can display version info if desired.
    public func preparePack(from packageURL: URL, language: String) async throws -> NLUPackManifest {
        logger.info("Preparation started for language: \(language)")
        let start = DispatchTime.now()

        stateLock.lock()
        defer { stateLock.unlock() }

        _stagingState = .downloaded

        // 1. Get a clean staging directory
        let stagingDir = try storage.stagingDirectory(for: language, clean: true)

        // 2. Extract and Validate
        _stagingState = .validating
        let manifest = try validator.extractAndValidate(from: packageURL, into: stagingDir)

        // 3. Mark as Ready
        // If validation succeeds, the package remains in `staging` safely until activation.
        self.preparedManifest = manifest
        _stagingState = .readyToActivate

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        logger.info("Preparation completed successfully in \(elapsed)s. State: readyToActivate.")

        return manifest
    }
    
    /// Safely activates the pack that was previously prepared in the staging directory.
    /// This performs a smoke test and atomically swaps the active directory.
    /// - Parameter language: The language code (e.g., "en").
    public func activatePreparedPack(language: String) async throws {
        logger.info("Activation started for language: \(language)")
        let start = DispatchTime.now()

        stateLock.lock()
        defer { stateLock.unlock() }

        guard _stagingState == .readyToActivate, let manifest = preparedManifest else {
            throw InstallerError.invalidStateForActivation
        }

        // Ensure we don't disrupt an active voice session
        guard engineProvider.isIdle else {
            logger.warning("Activation blocked: Engine is currently busy.")
            throw InstallerError.activationFailedEngineNotIdle
        }

        let stagingDir = try storage.stagingDirectory(for: language, clean: false)
        let version = manifest.version

        // TOKEN GUARD (C8) — the cached `preparedManifest` is only valid for the exact pack still
        // sitting in staging. If staging was wiped and rebuilt (e.g. a cancelled prepare followed
        // by a new one), the cached manifest no longer describes what is on disk. Re-read the
        // staging bundle.json and refuse to activate unless its version still matches.
        let stagedBundleURL = stagingDir.appendingPathComponent("bundle.json")
        guard
            let stagedData = try? Data(contentsOf: stagedBundleURL),
            let stagedManifest = try? JSONDecoder().decode(NLUPackManifest.self, from: stagedData),
            stagedManifest.version == version
        else {
            _stagingState = .failed
            throw InstallerError.invalidStateForActivation
        }

        // SMOKE TEST — Resolve model paths from manifest
        let resolution: ModelResolution
        do {
            resolution = try manifest.resolveModelPaths(for: language, relativeTo: stagingDir)
        } catch {
            _stagingState = .failed
            throw InstallerError.smokeTestFailed(error)
        }

        // 1. Independent Smoke Test Block
        do {
            try engineProvider.smokeTest(modelPath: resolution.modelURL, vocabularyPath: resolution.vocabularyURL)
        } catch {
            // If the model crashes, we fail the staging, but we don't break the existing models on disk.
            _stagingState = .failed
            throw InstallerError.smokeTestFailed(error)
        }

        // 2. Independent Filesystem Activation Block
        do {
            // ATOMIC ACTIVATION
            try storage.commitStagingAndActivate(version: version, for: language)

            // Clear the state
            self.preparedManifest = nil
            _stagingState = .active
        } catch {
            // Explicitly transition to a failed state if the filesystem operation fails
            _stagingState = .failed
            throw InstallerError.filesystemActivationFailed(error)
        }
    }
}
