import Foundation

/// Defines the protocol for the Host Application to provide the active inference engine.
/// Used to run a smoke test before a model is permanently activated.
public protocol NLUEngineProvider {
    /// Attempts to initialize the engine and run a lightweight smoke test.
    /// Should throw an error if the model is corrupted or incompatible.
    func smokeTest(modelPath: URL, vocabularyPath: URL) throws
    
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
public final class NLUPackInstaller {
    
    private let storage: PackStorageControlling
    private let validator: PackValidating
    private let engineProvider: NLUEngineProvider
    
    /// The parsed manifest from the most recent prepare operation.
    private var preparedManifest: NLUPackManifest?
    
    /// Tracks the state of the pack currently sitting in the staging directory.
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
    /// - Returns: The parsed manifest, so the Host App can display version info if desired.
    public func preparePack(from packageURL: URL, language: String) async throws -> NLUPackManifest {
        stagingState = .downloaded
        
        // 1. Get a clean staging directory
        let stagingDir = try storage.stagingDirectory(for: language)
        
        // 2. Extract and Validate
        stagingState = .validating
        let manifest = try validator.extractAndValidate(from: packageURL, into: stagingDir)
        
        // 3. Mark as Ready
        // If validation succeeds, the package remains in `staging` safely until activation.
        self.preparedManifest = manifest
        stagingState = .readyToActivate
        
        return manifest
    }
    
    /// Safely activates the pack that was previously prepared in the staging directory.
    /// This performs a smoke test and atomically swaps the active directory.
    /// - Parameter language: The language code (e.g., "en").
    public func activatePreparedPack(language: String) async throws {
        guard stagingState == .readyToActivate, let manifest = preparedManifest else {
            throw InstallerError.invalidStateForActivation
        }
        
        // Ensure we don't disrupt an active voice session
        guard engineProvider.isIdle else {
            throw InstallerError.activationFailedEngineNotIdle
        }
        
        let stagingDir = try storage.stagingDirectory(for: language, clean: false)
        let version = manifest.version
        
        // SMOKE TEST
        guard let modelInfo = manifest.models["intent"]?[language] ?? manifest.models["intent"]?["default"] else {
            throw InstallerError.smokeTestFailed(NSError(domain: "NLUPackInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: "Manifest missing intent model definition."]))
        }
        
        let modelURL = stagingDir.appendingPathComponent(modelInfo.artifact)
        
        // Resolve vocabulary dynamically from the manifest
        let vocabURL: URL
        if let vocabPath = modelInfo.vocabularyArtifact {
            vocabURL = stagingDir.appendingPathComponent(vocabPath)
        } else {
            // Fallback assumption for older manifests if needed
            vocabURL = modelURL.deletingLastPathComponent().appendingPathComponent("vocab.txt")
        }
        
        // 1. Independent Smoke Test Block
        do {
            try engineProvider.smokeTest(modelPath: modelURL, vocabularyPath: vocabURL)
        } catch {
            // If the model crashes, we fail the staging, but we don't break the existing models on disk.
            stagingState = .failed
            throw InstallerError.smokeTestFailed(error)
        }
        
        // 2. Independent Filesystem Activation Block
        do {
            // ATOMIC ACTIVATION
            try storage.commitStagingAndActivate(version: version, for: language)
            
            // Clear the state
            self.preparedManifest = nil
            stagingState = .active
        } catch {
            // Explicitly transition to a failed state if the filesystem operation fails
            stagingState = .failed
            throw InstallerError.filesystemActivationFailed(error)
        }
    }
}
