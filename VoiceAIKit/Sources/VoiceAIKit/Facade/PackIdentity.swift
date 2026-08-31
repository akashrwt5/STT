// PackIdentity.swift
// VoiceAIKit
//
// WHICH pack is this, exactly.
//
// A session used to be unable to answer that. The data was there — `ResolvedPack`
// holds the decoded `bundle.json` — but nothing on the facade exposed it, so a host
// asking "what was running when the user said it misheard them?" had two options,
// both wrong: reach into `ResolvedPack` (an internal type it should never name), or
// call `VoiceIntentClient.activePackVersion(for:)`, which re-reads `bundle.json`
// from disk and therefore answers a DIFFERENT question.
//
// That difference is not hypothetical. Activation is apply-on-next-build: an OTA
// pack becomes `Current` on disk while the running session keeps the pack it bound
// at `start()`. Between activation and the next session the two disagree, and the
// disk copy is the one that lies about what just happened.
//
// So identity comes from the loaded pack, and only from the loaded pack.

import Foundation

/// The pack a session is actually running, as declared by its own verified
/// `bundle.json`. Every field is read from the pack; none is derived or defaulted.
public struct PackIdentity: Sendable, Equatable {

    /// The compiler's bundle id, e.g. `pack-en-v1.0.36`.
    public let bundleID: String

    /// Semantic version, e.g. `1.0.36`.
    ///
    /// Read from the pack, never derived from `bundleID`. The compiler emits both
    /// from one variable so they agree by construction; deriving one from the other
    /// in client code would be a second source of truth that diverges only in the
    /// field, where nobody is looking.
    public let version: String

    /// SHA-256 root the signature covers — the strongest single identifier this
    /// pack has, and the one to log when "which bytes exactly?" matters.
    public let checksumRoot: String

    /// The `key_id` from `signature_info`. Says WHO signed, which is the field that
    /// tells a production build a dev-signed pack slipped through.
    public let keyID: String

    /// `"dev"`, `"production"`, … Verbatim from the pack; interpreting it is
    /// `PackTrustPolicy.refusesDevelopmentPacks`' job, not this type's.
    public let channel: String

    /// Which compiler build produced it, e.g. `nlu-compiler 1.0.0-content`.
    public let compilerVersion: String

    /// ISO-8601 build timestamp.
    public let createdAt: String

    /// Languages the pack declares, sorted.
    ///
    /// What the PACK carries — not what the session bound. The session's language is
    /// the host's own configuration and it already knows it; conflating the two would
    /// make this type mean something different depending on where it came from.
    public let languages: [String]

    init(_ manifest: NLUBundle) {
        self.bundleID        = manifest.bundleID
        self.version         = manifest.version
        self.checksumRoot    = manifest.checksumsRoot
        self.keyID           = manifest.signatureInfo.keyID
        self.channel         = manifest.channel
        self.compilerVersion = manifest.compilerVersion
        self.createdAt       = manifest.createdAt
        self.languages       = manifest.languages.keys.sorted()
    }
}

extension PackIdentity: CustomStringConvertible {
    /// One line, safe to log: identifiers only, nothing from the user's utterance.
    public var description: String {
        "\(bundleID) (v\(version), \(channel), key \(keyID), root \(checksumRoot.prefix(12))…)"
    }
}
