// VoiceIntentPack.swift
// VoiceAIKit
//
// Checks a host app can run on a pack without starting a session:
//  - `verify`: is the pack trusted and compatible?
//  - `smokeTest`: can the pack load and classify on this device?

import Foundation

/// Pack-level operations that do not need a live session.
public enum VoiceIntentPack {

    /// Checks that a pack on disk is trusted and compatible, and returns its identity.
    ///
    /// It runs the checks a session runs before it reads the pack's content:
    /// - the pack directory exists,
    /// - the signature is valid (skipped if `trust.skipsSignatureVerification` is true),
    /// - `checksums_root` matches, and every file's sha256 matches the manifest,
    /// - the pack has no file that the manifest does not list,
    /// - this SDK supports the pack's format and runtime requirements,
    /// - the pack is not a development pack, if `trust` refuses those,
    /// - the report-card gates passed, if `policy` requires it,
    /// - the pack has the requested language.
    ///
    /// It does not load the model or the pack's sections, so a pack that passes can
    /// still fail to load. Use `smokeTest` to check that.
    ///
    /// Use it to decide whether an installed pack can be served, and to fall back to
    /// the seed pack when it cannot.
    ///
    /// - Parameters:
    ///   - packRoot: The pack directory (the one that contains `bundle.json`).
    ///   - language: The language you want to serve. Verification fails if the pack
    ///     does not have it. If `nil`, the pack must contain exactly one language,
    ///     otherwise this throws `VoiceIntentError.languageAmbiguous`.
    ///   - trust: Which signing keys are trusted, and whether development packs are
    ///     refused.
    ///   - policy: Extra strictness settings (ignored file names, report-card gates).
    /// - Returns: The identity of the verified pack.
    /// - Throws: `VoiceIntentError` for the first check that failed.
    public static func verify(at packRoot: URL,
                              language: String? = nil,
                              trust: PackTrustPolicy,
                              policy: PackLoadPolicy = .default) throws -> PackIdentity {
        let (manifest, _) = try BundleDataLoader.verifiedManifest(
            packAt: packRoot, language: language, trust: trust, policy: policy)
        return PackIdentity(manifest)
    }

    /// Loads a pack the way a session does and classifies one utterance with it.
    ///
    /// It runs everything `verify` runs, then loads the pack's content and model.
    /// Use it before making a new pack current. A pack can pass every signature check
    /// and still not load on this device, for example when its model fails to load or
    /// a file the manifest lists is missing.
    ///
    /// If this throws, do not activate the pack. Keep the previous one.
    ///
    /// It uses the default engine settings, not any overrides set on a session.
    ///
    /// - Parameters:
    ///   - packRoot: The pack directory (the one that contains `bundle.json`).
    ///   - language: The language to load. It must be in the pack.
    ///   - trust: Which signing keys are trusted, and whether development packs are
    ///     refused.
    ///   - policy: Extra strictness settings, as in `verify`.
    ///   - probe: The text to classify. The result is thrown away. The test only
    ///     checks that classification completes.
    /// - Returns: The identity of the pack that was tested.
    public static func smokeTest(packRoot: URL,
                                 language: String,
                                 trust: PackTrustPolicy,
                                 policy: PackLoadPolicy = .default,
                                 probe: String = "hello") async throws -> PackIdentity {
        let pack = try BundleDataLoader.load(
            packAt: packRoot, language: language, trust: trust, policy: policy)
        let engine = try PackEngineFactory.makeEngine(pack: pack)
        _ = await engine.handle(probe)
        return PackIdentity(pack.manifest)
    }
}
