import Foundation
import OSLog

/// Defines the protocol for the Host Application to provide the active inference engine.
/// Used to run a smoke test before a model is permanently activated.
///
/// `Sendable`: the engine is shared across the OTA actor and the host, so conformers must be safe
/// to reference from any isolation domain.
public protocol NLUEngineProvider: Sendable {
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

/// The main orchestration type for NLU over-the-air updates.
/// The Host Application uses this to prepare downloaded zips and activate them when safe.
///
/// An `actor`, not a lock-guarded class. The previous version was `@unchecked Sendable`
/// with an `NSLock`, which meant the compiler was not checking a promise every host
/// depends on: add one mutable property and forget the lock, and nothing complains.
///
/// WHAT THE ACTOR DOES NOT GIVE YOU, and why the state guards below are still here:
/// actor isolation is not mutual exclusion across `await`. Both public methods suspend —
/// `activatePreparedPack` at the smoke test, `preparePack` at the extraction hop — and a
/// second caller enters the actor at that point. `stagingState` is what rejects it, and
/// the `guard`s in `claimForActivation()` / `commitActive()` are load-bearing for that
/// reason, not as leftovers from the lock. Inlining them is how the race comes back.
public actor NLUPackInstaller {

    private let storage: PackStorageControlling
    private let validator: PackValidating
    private let engineProvider: NLUEngineProvider

    private let logger = Logger(subsystem: "com.starkey.voiceaikit", category: "OTAInstaller")

    /// The identity of the pack admitted by the most recent prepare operation.
    private var preparedPack: PackIdentity?

    /// The state of the pack currently sitting in the staging directory.
    ///
    /// `await`-only now that this is an actor. That is a source-breaking change for a
    /// host that reads it; `preparePack` and `activatePreparedPack` were already `async`
    /// and are unaffected.
    public private(set) var stagingState: PackState = .downloaded

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
    /// - Returns: The identity of the admitted pack, so the Host App can display or log which
    ///   version it is about to activate. This is the same `PackIdentity` a running
    ///   `VoiceIntentSession` reports as `loadedPack`.
    public func preparePack(from packageURL: URL, language: String) async throws -> PackIdentity {
        logger.info("Preparation started for language: \(language)")
        let start = DispatchTime.now()

        // Claim the staging directory before doing anything to it.
        //
        // Under the old lock the whole method ran inside one critical section, so two
        // concurrent prepares serialised. This body now suspends at the extraction hop
        // below, so without this guard a second caller would wipe and re-extract staging
        // underneath the first — and the first would return an identity describing the
        // second one's bytes. `.validating` is the same transient state activation
        // claims, which is correct: neither may run while the other holds staging.
        guard stagingState != .validating else {
            logger.warning("Preparation refused: staging is already being prepared or activated.")
            throw InstallerError.invalidStateForActivation
        }
        stagingState = .validating

        do {
            // 1. Get a clean staging directory
            let stagingDir = try storage.stagingDirectory(for: language, clean: true)

            // 2. Extract and validate — OFF the actor.
            //
            // This is a synchronous unzip plus a sha256 over every file in the pack. Under
            // the old `NSLock` it blocked the caller's own thread; left inline on an actor
            // it would block a cooperative-pool thread instead, which is worse — that pool
            // is bounded and shared with everything else in the process.
            let validator = self.validator
            let identity = try await Task.detached(priority: .utility) {
                try validator.extractAndValidate(from: packageURL, into: stagingDir)
            }.value

            // 3. Mark as Ready. Re-check first: the claim above is what should have kept
            //    this true across the suspension, so a violation means an unaccounted-for
            //    writer rather than an expected race.
            guard stagingState == .validating else {
                throw InstallerError.invalidStateForActivation
            }
            self.preparedPack = identity
            stagingState = .readyToActivate

            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            logger.info("Preparation completed successfully in \(elapsed)s. State: readyToActivate.")

            return identity
        } catch {
            // The claim must not outlive a failed prepare, or every later call is refused.
            stagingState = .failed
            throw error
        }
    }

    /// Safely activates the pack that was previously prepared in the staging directory.
    /// This runs a real smoke test (async) and then atomically swaps the active directory.
    /// - Parameter language: The language code (e.g., "en").
    ///
    /// The flow is still claim -> (await smoke test) -> commit, in three guarded steps. On
    /// the lock-based version that shape existed because awaiting under a lock is unsafe.
    /// It survives for a different reason: the smoke test is a suspension point, a second
    /// `activatePreparedPack` enters the actor there, and the transient `.validating` state
    /// is what makes it lose. Same behaviour, different mechanism.
    public func activatePreparedPack(language: String) async throws {
        logger.info("Activation started for language: \(language)")

        // 1. Claim: verify we are ready + idle, then move to the transient `.validating` state.
        let prepared = try claimForActivation()
        let version = prepared.version
        let stagingDir = try storage.stagingDirectory(for: language, clean: false)

        // TOKEN GUARD (C8) — the cached `preparedPack` is only valid for the exact pack still
        // sitting in staging. If staging was wiped and rebuilt, refuse to activate.
        //
        // Matched on `checksums_root`, not on `version`. The version is a label the compiler
        // chooses and two different builds can carry the same one — a rebuild of 1.0.38 is still
        // 1.0.38 — so a version match does not establish that these are the bytes we verified.
        // `checksums_root` is the digest the signature covers: it matches only for the pack that
        // passed validation. The version is compared too, so a mismatch is legible in a log
        // rather than being a bare digest disagreement.
        //
        // These bytes are read from staging, NOT re-verified, which is exactly why the comparison
        // has to be against something a rewrite cannot fake without also breaking the signature
        // the next load will check.
        let stagedBundleURL = stagingDir.appendingPathComponent("bundle.json")
        guard
            let stagedData = try? Data(contentsOf: stagedBundleURL),
            let stagedManifest = try? JSONDecoder().decode(NLUBundle.self, from: stagedData),
            stagedManifest.checksumsRoot == prepared.checksumRoot,
            stagedManifest.version == version
        else {
            markFailed()
            throw InstallerError.invalidStateForActivation
        }

        // 2. Real smoke test — build an engine from staging and run one inference. This is the
        //    suspension point the claim above exists to survive.
        do {
            try await engineProvider.smokeTest(packRoot: stagingDir, language: language)
        } catch {
            // The model does not load on this device: fail staging, leave the existing on-disk
            // models untouched. A bad pack never becomes `Current`.
            markFailed()
            throw InstallerError.smokeTestFailed(error)
        }

        // 3. Commit: atomic activation.
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

    // MARK: - Activation state transitions

    /// Verifies the installer is ready and the engine is idle, then transitions to the transient
    /// `.validating` state and returns the prepared pack's identity.
    ///
    /// Synchronous on purpose: it must not suspend, or the window it exists to close reopens
    /// inside the claim itself.
    private func claimForActivation() throws -> PackIdentity {
        guard stagingState == .readyToActivate, let prepared = preparedPack else {
            throw InstallerError.invalidStateForActivation
        }
        // Ensure we don't disrupt an active voice session.
        guard engineProvider.isIdle else {
            logger.warning("Activation blocked: Engine is currently busy.")
            throw InstallerError.activationFailedEngineNotIdle
        }
        stagingState = .validating
        return prepared
    }

    /// Commits staging -> active atomically. Requires the transient `.validating` state set by
    /// `claimForActivation`; throws `invalidStateForActivation` if a re-entrant caller changed it.
    /// Synchronous, for the same reason as the claim.
    private func commitActive(version: String, language: String) throws {
        guard stagingState == .validating else {
            throw InstallerError.invalidStateForActivation
        }
        try storage.commitStagingAndActivate(version: version, for: language)
        self.preparedPack = nil
        stagingState = .active
    }

    private func markFailed() {
        stagingState = .failed
    }
}
