// VoiceIntentClient.swift
// VoiceAIKit
//
// Pack management for the host app: prepare and activate OTA packs, and report
// which pack version is on disk. Live voice sessions are handled by
// `VoiceIntentSession`.

import Foundation

/// Errors thrown by `VoiceIntentClient`.
public enum VoiceIntentClientError: Error, LocalizedError {
    case noValidModelFound
    /// The seed pack could not be loaded. The associated error is the cause.
    case seedPackInvalid(Error)
    
    public var errorDescription: String? {
        switch self {
        case .noValidModelFound: return "Failed to start the engine because no valid OTA or seed models were found."
        case .seedPackInvalid(let e): return "The bundled seed pack is invalid or corrupted: \(e.localizedDescription)"
        }
    }
}

/// Manages installed packs: installing and activating OTA packs, and reporting
/// which pack version is on disk.
///
/// Create one instance in the host app and keep a reference to it (do not use a
/// singleton). It is safe to use from any thread: it has no changing state of its
/// own, `installer` is an actor, and `PackStorageController` uses a lock.
public final class VoiceIntentClient: Sendable {
    
    /// Prepares and activates new OTA packs.
    public let installer: NLUPackInstaller
    
    private let storage: PackStorageControlling
    private let engineProvider: NLUEngineProvider
    
    /// True when the engine is not handling a request.
    public var isEngineIdle: Bool {
        return engineProvider.isIdle
    }
    private let seedPackURL: URL
    
    /// - Parameters:
    ///   - storage: Manages where packs are stored on disk.
    ///   - validator: Checks a downloaded pack (signature and compatibility) before install.
    ///   - engineProvider: The engine used to test-load a new pack and to load models.
    ///   - seedPackURL: The pack directory shipped with the app.
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
    
    /// The version of the pack that is current on disk for `language`.
    ///
    /// If there is no current pack, or its `bundle.json` cannot be read, this returns
    /// the seed pack's version. It returns `nil` if neither can be read.
    ///
    /// This is not always the pack a session is running. A session keeps the pack it
    /// loaded at `start()`, so after a new pack is activated the two differ until the
    /// next session starts. To know which pack handled a request, read
    /// `VoiceIntentSession.loadedPack`.
    public func activePackVersion(for language: String) -> String? {
        if let currentURL = storage.currentPack(for: language),
           let manifest = Self.decodeManifest(at: currentURL) {
            return manifest.version
        }
        return Self.decodeManifest(at: seedPackURL)?.version
    }

    /// Reads and decodes `bundle.json` in a pack directory. Returns `nil` if it is
    /// missing or invalid. It only reads the file; it does not verify the pack.
    private static func decodeManifest(at packRoot: URL) -> NLUBundle? {
        guard let data = try? Data(contentsOf: packRoot.appendingPathComponent("bundle.json"))
        else { return nil }
        return try? JSONDecoder().decode(NLUBundle.self, from: data)
    }
    
    /// Loads a pack's model for `language` into the engine.
    ///
    /// It tries the current OTA pack first. If that pack cannot be loaded, it rolls
    /// back to the previous version and tries again, up to 3 packs in total. If no
    /// OTA pack works, it loads the seed pack. A rollback changes which pack is
    /// current on disk.
    ///
    /// A pack cannot be loaded if its `bundle.json` is missing a required field or
    /// its model fails to load. This does not verify signatures. `VoiceIntentSession`
    /// loads and verifies its own pack, so a live session does not need this call.
    ///
    /// - Throws: `VoiceIntentClientError.seedPackInvalid` if the seed pack cannot be loaded.
    public func start(for language: String) async throws {
        var didLoadActive = false
        
        // 1. Try to load the active OTA pack
        if storage.hasActivePack(for: language) {
            didLoadActive = await attemptLoadActivePack(for: language)
        }
        
        // 2. Fallback to Seed Pack if no OTA pack exists, or if they all failed & rolled back
        if !didLoadActive {
            try await loadSeedPack(for: language)
        }
    }
    
    /// Loads the current pack for `language`. If that fails, it rolls back to the
    /// previous version and tries again.
    ///
    /// It returns `false` instead of throwing when no OTA pack can be loaded,
    /// including when there is no previous version to roll back to. `start(for:)`
    /// then loads the seed pack.
    ///
    /// - Parameter retriesRemaining: How many more packs to try. It stops the recursion.
    private func attemptLoadActivePack(for language: String, retriesRemaining: Int = 3) async -> Bool {
        guard retriesRemaining > 0 else { return false }
        guard let currentURL = storage.currentPack(for: language) else { return false }

        // No `bundle.json`: treat the pack as broken and roll back. If there is nothing
        // to roll back to, give up (the caller loads the seed pack).
        let bundleURL = currentURL.appendingPathComponent("bundle.json")
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            guard (try? storage.rollback(for: language)) != nil else { return false }
            return await attemptLoadActivePack(for: language, retriesRemaining: retriesRemaining - 1)
        }

        do {
            let data = try Data(contentsOf: bundleURL)
            let manifest = try JSONDecoder().decode(NLUBundle.self, from: data)
            let resolution = try manifest.resolveModelPaths(for: language, relativeTo: currentURL)

            // Load the model into the engine
            try engineProvider.load(modelPath: resolution.modelURL, vocabularyPath: resolution.vocabularyURL)

            // The model is loaded.
            return true

        } catch {
            // `bundle.json` could not be decoded, or the model failed to load.
            // Roll back and try the previous version. If there is none, give up.
            guard (try? storage.rollback(for: language)) != nil else { return false }
            return await attemptLoadActivePack(for: language, retriesRemaining: retriesRemaining - 1)
        }
    }
    
    /// Loads the seed pack (the pack shipped inside the app) into the engine.
    ///
    /// - Throws: `VoiceIntentClientError.seedPackInvalid` if `bundle.json` cannot be
    ///   read or decoded, or the model fails to load.
    private func loadSeedPack(for language: String) async throws {
        let bundleURL = seedPackURL.appendingPathComponent("bundle.json")
        
        do {
            let data = try Data(contentsOf: bundleURL)
            let manifest = try JSONDecoder().decode(NLUBundle.self, from: data)
            let resolution = try manifest.resolveModelPaths(for: language, relativeTo: seedPackURL)
            
            // Load the seed model into the engine
            try engineProvider.load(modelPath: resolution.modelURL, vocabularyPath: resolution.vocabularyURL)
            
        } catch {
            throw VoiceIntentClientError.seedPackInvalid(error)
        }
    }
}
