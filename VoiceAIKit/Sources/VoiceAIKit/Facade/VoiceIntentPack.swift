// VoiceIntentPack.swift
// VoiceAIKit
//
// The two things a host does to a pack that are not "run a session with it":
// check whether it is safe to serve, and rehearse loading it before making it live.
//
// Both already existed — as instructions to copy. `PackProviderForApp` calls
// `PackIntegrity.verify` directly; `STTNLUEngineProvider.smokeTest` strings together
// `BundleDataLoader.load` + `PackEngineFactory.makeEngine` + `engine.handle("hello")`.
// That is four internal types named in host code to perform two operations the SDK
// should simply offer, and every future host copies the same four lines from the last
// one. Copy them with a different `PackTrustPolicy` than the session uses — easy, the
// argument is right there — and the OTA activation gate silently checks something
// other than what will actually run.
//
// Offering them here is what lets `Data/` stop being public.

import Foundation

/// Pack-level operations that do not need a live session.
public enum VoiceIntentPack {

    /// Verify a pack on disk and return what it says it is.
    ///
    /// Runs the same checks a real load runs — ed25519 signature over
    /// `manifest ‖ bundle.json`, `checksums_root` binding, every file's digest,
    /// `min_runtime_contract`, the development-pack refusal, report-card gates, and
    /// language availability — and stops before reading the pack's content. So it
    /// answers "would this load?", not "does its sha256 add up?", while costing a
    /// fraction of a load.
    ///
    /// Intended for the read side of an OTA setup: a `PackProvider` deciding whether
    /// the activated pack is fit to serve, and falling back to the seed when it is not.
    ///
    /// - Parameters:
    ///   - packRoot: the pack directory (the one holding `bundle.json`).
    ///   - language: if given, verification fails unless the pack carries it. Pass the
    ///     language you are about to serve — a pack that verifies perfectly and does
    ///     not speak your language is not a pack you can use.
    ///   - trust: who is allowed to have signed it.
    /// - Throws: `VoiceIntentError` describing which step failed.
    public static func verify(at packRoot: URL,
                              language: String? = nil,
                              trust: PackTrustPolicy,
                              policy: PackLoadPolicy = .default) throws -> PackIdentity {
        let (manifest, _) = try BundleDataLoader.verifiedManifest(
            packAt: packRoot, language: language, trust: trust, policy: policy)
        return PackIdentity(manifest)
    }

    /// Load a pack exactly as a live session would and run one classification through it.
    ///
    /// This is the dress rehearsal an OTA installer needs before making a staged pack
    /// `Current`: a pack can pass every cryptographic check and still be unloadable on
    /// this device — a CoreML model the OS refuses, a section the compiler emitted
    /// wrongly, an artifact the manifest promised and did not ship. Signature checks
    /// cannot see any of that; only loading it can.
    ///
    /// Throwing from here is the signal to abort activation, so the previous pack stays
    /// `Current` and the user keeps a working assistant.
    ///
    /// - Parameter probe: the utterance to classify. The result is discarded — what is
    ///   being tested is that classification completes at all, not what it returns.
    /// - Returns: the identity of the pack that was successfully exercised.
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
