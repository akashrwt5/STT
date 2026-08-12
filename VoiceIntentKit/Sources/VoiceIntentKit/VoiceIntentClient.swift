import Foundation

public enum VoiceIntentClientError: Error, LocalizedError {
    case noValidModelFound
    case seedPackInvalid(Error)
    
    public var errorDescription: String? {
        switch self {
        case .noValidModelFound: return "Failed to start the engine because no valid OTA or seed models were found."
        case .seedPackInvalid(let e): return "The bundled seed pack is invalid or corrupted: \(e.localizedDescription)"
        }
    }
}

/// The main entry point for the VoiceIntentKit SDK.
/// The Host Application should instantiate this class (avoiding Singletons) and hold a strong reference to it.
///
/// Thread Safety: This class is fully stateless and thread-safe. All mutable state is isolated within the `NLUPackInstaller` actor.
public final class VoiceIntentClient: Sendable {
    
    /// The orchestration layer for preparing and activating new OTA packages.
    public let installer: NLUPackInstaller
    
    private let storage: PackStorageControlling
    private let engineProvider: NLUEngineProvider
    
    /// Returns true if the inference engine is not currently processing a request.
    public var isEngineIdle: Bool {
        return engineProvider.isIdle
    }
    private let seedPackURL: URL
    
    /// Initializes the SDK client.
    /// - Parameters:
    ///   - storage: The storage controller managing the `.nlu` filesystem.
    ///   - validator: The validator checking signatures and compatibility.
    ///   - engineProvider: The inference engine wrapper used to run smoke tests and load models.
    ///   - seedPackURL: The URL to the pre-bundled factory pack (e.g., in the App Bundle).
    public init(
        storage: PackStorageControlling,
        validator: PackValidating,
        engineProvider: NLUEngineProvider,
        seedPackURL: URL
    ) {
        self.storage = storage
        self.engineProvider = engineProvider
        self.seedPackURL = seedPackURL
        
        self.installer = NLUPackInstaller(
            storage: storage,
            validator: validator,
            engineProvider: engineProvider
        )
    }
    
    /// Retrieves the version of the currently active pack (OTA or Seed) for the given language.
    public func activePackVersion(for language: String) -> String? {
        if let currentURL = storage.currentPack(for: language) {
            let bundleURL = currentURL.appendingPathComponent("bundle.json")
            if let data = try? Data(contentsOf: bundleURL),
               let manifest = try? JSONDecoder().decode(NLUPackManifest.self, from: data) {
                return manifest.version
            }
        }
        
        let seedBundleURL = seedPackURL.appendingPathComponent("bundle.json")
        if let data = try? Data(contentsOf: seedBundleURL),
           let manifest = try? JSONDecoder().decode(NLUPackManifest.self, from: data) {
            return manifest.version
        }
        
        return nil
    }
    
    /// Starts the SDK for the specified language.
    /// This resolves the best available model (OTA or Seed) and loads it into the engine.
    /// It automatically handles rollback if the active OTA package is corrupted.
    public func start(for language: String) async throws {
        var didLoadActive = false
        
        // 1. Try to load the active OTA pack
        if storage.hasActivePack(for: language) {
            didLoadActive = try await attemptLoadActivePack(for: language)
        }
        
        // 2. Fallback to Seed Pack if no OTA pack exists, or if they all failed & rolled back
        if !didLoadActive {
            try await loadSeedPack(for: language)
        }
    }
    
    /// Recursively attempts to load the currently active pack. If it fails, it rolls back and tries the older version.
    /// - Parameter retriesRemaining: Maximum number of rollback attempts to prevent infinite recursion.
    private func attemptLoadActivePack(for language: String, retriesRemaining: Int = 3) async throws -> Bool {
        guard retriesRemaining > 0 else { return false }
        guard let currentURL = storage.currentPack(for: language) else { return false }
        
        // Ensure bundle.json exists
        let bundleURL = currentURL.appendingPathComponent("bundle.json")
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            // Corrupted! Rollback to the previous version
            do {
                try storage.rollback(for: language)
                return try await attemptLoadActivePack(for: language, retriesRemaining: retriesRemaining - 1)
            } catch {
                return false
            }
        }
        
        do {
            let data = try Data(contentsOf: bundleURL)
            let manifest = try JSONDecoder().decode(NLUPackManifest.self, from: data)
            let resolution = try manifest.resolveModelPaths(for: language, relativeTo: currentURL)
            
            // Load the model into the live engine
            try engineProvider.load(modelPath: resolution.modelURL, vocabularyPath: resolution.vocabularyURL)
            
            // Success! The model is active.
            return true
            
        } catch {
            // Either JSON parsing failed or the engine failed to load the model.
            // Rollback and try the older version.
            do {
                try storage.rollback(for: language)
                return try await attemptLoadActivePack(for: language, retriesRemaining: retriesRemaining - 1)
            } catch {
                return false
            }
        }
    }
    
    /// Loads the guaranteed safe seed pack bundled inside the iOS App.
    private func loadSeedPack(for language: String) async throws {
        let bundleURL = seedPackURL.appendingPathComponent("bundle.json")
        
        do {
            let data = try Data(contentsOf: bundleURL)
            let manifest = try JSONDecoder().decode(NLUPackManifest.self, from: data)
            let resolution = try manifest.resolveModelPaths(for: language, relativeTo: seedPackURL)
            
            // Load the seed model into the live engine
            try engineProvider.load(modelPath: resolution.modelURL, vocabularyPath: resolution.vocabularyURL)
            
        } catch {
            throw VoiceIntentClientError.seedPackInvalid(error)
        }
    }
}
