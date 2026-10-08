// PackIdentity.swift
// VoiceAIKit
//
// Describes the pack a session is running: its version, signer, channel and
// checksum. Read it from `VoiceIntentSession.loadedPack`.

import Foundation

/// The pack a session is actually running, as declared by its own verified
/// `bundle.json`. Every field is read from the pack; none is derived or defaulted.
public struct PackIdentity: Sendable, Equatable {

    /// The compiler's bundle id, e.g. `pack-en-v1.0.36`.
    public let bundleID: String

    /// Pack version, e.g. `1.0.36`. Copied from the pack's `version` field.
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
