import Foundation
import OSLog

/// Defines the protocol for the Host Application to provide the active inference engine.
/// Used to run a smoke test before a model is permanently activated.
public protocol NLUEngineProvider {
    /// Builds an engine from the *staged* pack and runs a lightweight inference, throwing if the
    /// pack cannot actually be loaded on this device.
    ///
    /// This receives the pack ROOT (the staging directory), not resolved model/vocab paths, so the
    /// host can load it through the exact same path a live `VoiceIntentSession` uses
    /// (`BundleDataLoader` + `PackEngineFactory`). That makes the smoke test a true dress rehearsal:
    /// if it passes, the next session load will succeed; if it throws, the pack is never activated,
    /// so a crypto-valid but device-unloadable pack can never become `Current`. It is `async`
    /// because building a CoreML-backed engine and running one classification is async.
    func smokeTest(packRoot: URL, language: String) async throws

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
    /// This runs a real smoke test (async) and then atomically swaps the active directory.
    /// - Parameter language: The language code (e.g., "en").
    ///
    /// The smoke test is `async`, and awaiting under a lock is unsafe, so the flow is split into
    /// three short critical sections — claim → (await smoke test, no lock) → commit — each guarded
    /// by `stateLock`. The transient `.validating` state between claim and commit means a second,
    /// racing `activatePreparedPack` is rejected (`commitActive` requires `.validating`).
    public func activatePreparedPack(language: String) async throws {
        logger.info("Activation started for language: \(language)")

        // 1. Claim: verify we are ready + idle, then move to the transient `.validating` state.
        let manifest = try claimForActivation()
        let version = manifest.version
        let stagingDir = try storage.stagingDirectory(for: language, clean: false)

        // TOKEN GUARD (C8) — the cached `preparedManifest` is only valid for the exact pack still
        // sitting in staging. If staging was wiped and rebuilt, refuse to activate.
        let stagedBundleURL = stagingDir.appendingPathComponent("bundle.json")
        guard
            let stagedData = try? Data(contentsOf: stagedBundleURL),
            let stagedManifest = try? JSONDecoder().decode(NLUPackManifest.self, from: stagedData),
            stagedManifest.version == version
        else {
            markFailed()
            throw InstallerError.invalidStateForActivation
        }

        // 2. Real smoke test — build an engine from staging and run one inference. No lock held.
        do {
            try await engineProvider.smokeTest(packRoot: stagingDir, language: language)
        } catch {
            // The model does not load on this device: fail staging, leave the existing on-disk
            // models untouched. A bad pack never becomes `Current`.
            markFailed()
            throw InstallerError.smokeTestFailed(error)
        }

        // 3. Commit: atomic activation under the lock.
        do {
            try commitActive(version: version, language: language)
        } catch is InstallerError {
            throw InstallerError.invalidStateForActivation
        } catch {
            markFailed()
            throw InstallerError.filesystemActivationFailed(error)
        }

        logger.info("Activation completed for language: \(language). Version: \(version)")
    }

    // MARK: - Activation critical sections

    /// Verifies the installer is ready and the engine is idle, then transitions to the transient
    /// `.validating` state and returns the prepared manifest. Locked.
    private func claimForActivation() throws -> NLUPackManifest {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _stagingState == .readyToActivate, let manifest = preparedManifest else {
            throw InstallerError.invalidStateForActivation
        }
        // Ensure we don't disrupt an active voice session.
        guard engineProvider.isIdle else {
            logger.warning("Activation blocked: Engine is currently busy.")
            throw InstallerError.activationFailedEngineNotIdle
        }
        _stagingState = .validating
        return manifest
    }

    /// Commits staging → active atomically. Requires the transient `.validating` state set by
    /// `claimForActivation`; throws `invalidStateForActivation` if a racing caller changed it. Locked.
    private func commitActive(version: String, language: String) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _stagingState == .validating else {
            throw InstallerError.invalidStateForActivation
        }
        try storage.commitStagingAndActivate(version: version, for: language)
        self.preparedManifest = nil
        _stagingState = .active
    }

    private func markFailed() {
        stateLock.lock(); defer { stateLock.unlock() }
        _stagingState = .failed
    }
}
