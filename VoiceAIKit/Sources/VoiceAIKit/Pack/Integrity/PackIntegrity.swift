// PackIntegrity.swift
// VoiceAIKit
//
// The trust chain, verified BEFORE anything in the pack is parsed (ADD §8).
//
// Order matters and is not negotiable:
//
//   1. Ed25519-verify `integrity/signature.sig` over
//      `integrity/manifest.sha256` ‖ `bundle.json`
//   2. assert `bundle.json.checksums_root == sha256(manifest.sha256)`
//   3. verify every digest listed in the manifest
//
// Step 2 is easy to mistake for redundant. It is not: `bundle.json` is
// deliberately NOT listed inside the manifest, so `checksums_root` is the only
// thing binding the two together. Drop it and an attacker can swap the manifest
// wholesale.
//
// CANONICALISATION IS LOAD-BEARING. The compiler writes both files with sorted
// keys, `(",", ":")` separators, NFC-normalised strings and a trailing newline,
// then signs those exact bytes. A client that decodes and re-encodes JSON before
// hashing will fail verification for reasons that look like corruption. So both
// files are read as `Data` and never round-tripped through `JSONSerialization`.
// (Confirmed against `packages/buildtime/nlu_compiler/build.py`, which signs
// `sha_table + manifest_bytes`.)

import CryptoKit
import Foundation

/// Where the public key for a pack's `key_id` comes from, and which packs are
/// acceptable at all.
///
/// Host-supplied rather than pinned in the SDK so key rotation does not require
/// an SDK release.
public struct PackTrustPolicy: Sendable {

    /// Raw 32-byte Ed25519 public keys, by `key_id`.
    public let publicKeys: [String: Data]

    /// Refuse development packs. ADR-005 Part 11 requires a production runtime
    /// to categorically refuse dev-signed artifacts, by channel AND key id.
    public let refusesDevelopmentPacks: Bool

    /// Skip signature verification entirely. Tests and local pack authoring
    /// only — `refusesDevelopmentPacks` must be false for this to be reachable,
    /// so a release build cannot accidentally take this path.
    public let skipsSignatureVerification: Bool

    public init(publicKeys: [String: Data] = [:],
                refusesDevelopmentPacks: Bool = true,
                skipsSignatureVerification: Bool = false) {
        self.publicKeys = publicKeys
        self.refusesDevelopmentPacks = refusesDevelopmentPacks
        self.skipsSignatureVerification = skipsSignatureVerification
    }

    /// Unsigned, accepts dev packs. For tests and pack authoring.
    public static let unverifiedForTesting = PackTrustPolicy(
        refusesDevelopmentPacks: false, skipsSignatureVerification: true)
}

/// How strict to be about things that are wrong but not dangerous.
public struct PackLoadPolicy: Sendable {

    /// Files allowed to exist without a manifest entry. Filesystem litter only.
    ///
    /// Real packs ship `.DS_Store` (BUG-018): `pack-en-v1.0.28` has two, and
    /// they are correctly excluded from the manifest, so a strict reading makes
    /// every current pack unloadable. Unsigned files cannot affect anything
    /// signed, so ignoring known junk is safe — ignoring *arbitrary* unsigned
    /// files would not be, which is why this is a fixed list and not a flag.
    public let ignoredFileNames: Set<String>

    /// Declared artifacts allowed to be absent.
    ///
    /// Both entries below are LEGACY, and both are fixed in the compiler as of
    /// the change that turned `verifyDeclaredArtifacts` on. They are listed only
    /// so that packs built BEFORE that fix — including the seed pack vendored in
    /// this repo — still load while the first corrected pack is being built.
    ///
    /// **Delete both entries once no supported pack declares them**, and this set
    /// goes back to being empty, which is the state it should live in. A
    /// tolerance list that accumulates is how a check stops being one.
    ///
    ///   * `models/semantic_head/shared/head.json` — declared by every pack the
    ///     compiler used to emit and shipped by none (VIK-010). The compiler now
    ///     declares a semantic head only when it has one to ship;
    ///     `models.semantic_head` is optional in the bundle schema, which is the
    ///     way out the original code was looking for.
    ///   * `models/intent/en/model.onnx` — the iOS slice deleted the ONNX and
    ///     kept declaring it (VIK-051). `mod_ios` now repoints `artifact` at the
    ///     compiled CoreML head (`format: "mlmodelc-ref"`) when it removes the
    ///     ONNX. Exact path, not a pattern, so a second language cannot inherit
    ///     the exemption by accident — `en` is the only pack this ever shipped in.
    public let toleratedMissingArtifacts: Set<String>

    /// Refuse a pack whose own report card says its gates did not pass.
    public let requiresPassingGates: Bool

    public init(ignoredFileNames: Set<String> = [".DS_Store", "Thumbs.db"],
                toleratedMissingArtifacts: Set<String> = [
                    "models/semantic_head/shared/head.json",   // VIK-010, delete after 1.0.46
                    "models/intent/en/model.onnx",             // VIK-051, delete after 1.0.46
                ],
                requiresPassingGates: Bool = true) {
        self.ignoredFileNames = ignoredFileNames
        self.toleratedMissingArtifacts = toleratedMissingArtifacts
        self.requiresPassingGates = requiresPassingGates
    }

    public static let `default` = PackLoadPolicy()
}

// MARK: -

enum PackIntegrity {

    static let manifestPath = "integrity/manifest.sha256"
    static let signaturePath = "integrity/signature.sig"
    static let bundlePath = "bundle.json"

    /// Result of a successful verification: the digest table, and the exact
    /// bytes of `bundle.json` that were covered by the signature. Callers decode
    /// the manifest from these bytes rather than re-reading the file, so what
    /// gets parsed is provably what got verified.
    struct Verified: Sendable {
        let digests: [String: String]
        let bundleJSONBytes: Data
    }

    /// Run the full chain. Throws on the first failure.
    static func verify(packRoot: URL,
                              trust: PackTrustPolicy,
                              policy: PackLoadPolicy = .default) throws -> Verified {

        let manifestData = try readOpaque(packRoot, manifestPath)
        let bundleData = try readOpaque(packRoot, bundlePath)

        // --- 1. signature over manifest ‖ bundle.json -----------------------
        if !trust.skipsSignatureVerification {
            let signature = try readOpaque(packRoot, signaturePath)
            let keyID = try signingKeyID(from: bundleData)
            guard let keyBytes = trust.publicKeys[keyID] else {
                throw VoiceIntentError.signingKeyUnknown(keyID: keyID)
            }
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
            guard key.isValidSignature(signature, for: manifestData + bundleData) else {
                throw VoiceIntentError.signatureInvalid
            }
        }

        // --- 2. checksums_root binds bundle.json to the manifest ------------
        let root = try checksumsRoot(from: bundleData)
        let actual = sha256Hex(manifestData)
        guard root == actual else {
            throw VoiceIntentError.checksumsRootMismatch(expected: root, actual: actual)
        }

        // --- 3. every listed digest ----------------------------------------
        let digests = try parseManifest(manifestData)
        for (relative, expected) in digests {
            let url = packRoot.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url) else {
                throw VoiceIntentError.integrityFileMissing(path: relative)
            }
            guard sha256Hex(data) == expected else {
                throw VoiceIntentError.fileDigestMismatch(path: relative)
            }
        }

        // --- 4. nothing unsigned is hiding in the tree ----------------------
        let unsigned = try unsignedFiles(packRoot: packRoot, listed: Set(digests.keys), policy: policy)
        guard unsigned.isEmpty else {
            throw VoiceIntentError.unsignedFilesPresent(unsigned)
        }

        return Verified(digests: digests, bundleJSONBytes: bundleData)
    }

    // MARK: - Pieces

    /// Read a file as bytes. Never decode-and-re-encode: the signature covers
    /// the compiler's exact serialization.
    static func readOpaque(_ root: URL, _ relative: String) throws -> Data {
        let url = root.appendingPathComponent(relative)
        do { return try Data(contentsOf: url) }
        catch { throw VoiceIntentError.integrityFileMissing(path: relative) }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `<hex>  <relative/path>`, two spaces, one per line — sha256sum format.
    static func parseManifest(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceIntentError.malformedJSON(path: manifestPath, reason: "not UTF-8")
        }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let sep = line.range(of: "  ") else {
                throw VoiceIntentError.malformedJSON(path: manifestPath,
                                                     reason: "unparsable line: \(line.prefix(64))")
            }
            out[String(line[sep.upperBound...])] = String(line[..<sep.lowerBound])
        }
        guard !out.isEmpty else {
            throw VoiceIntentError.malformedJSON(path: manifestPath, reason: "no entries")
        }
        return out
    }

    /// Files on disk with no manifest entry, ignoring known filesystem litter.
    /// `bundle.json` and `integrity/` are excluded by design.
    static func unsignedFiles(packRoot: URL,
                              listed: Set<String>,
                              policy: PackLoadPolicy) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: packRoot,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        let exempt: Set<String> = [bundlePath, manifestPath, signaturePath]
        var extras: [String] = []
        let prefix = packRoot.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            if policy.ignoredFileNames.contains(url.lastPathComponent) { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            if exempt.contains(relative) || listed.contains(relative) { continue }
            extras.append(relative)
        }
        return extras.sorted()
    }

    // MARK: - Minimal reads out of bundle.json
    //
    // Pulled with JSONSerialization rather than Codable because they are needed
    // BEFORE the manifest is trusted enough to decode fully.

    static func signingKeyID(from bundleData: Data) throws -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: bundleData) as? [String: Any],
            let info = obj["signature_info"] as? [String: Any],
            let keyID = info["key_id"] as? String
        else {
            throw VoiceIntentError.malformedJSON(path: bundlePath, reason: "signature_info.key_id absent")
        }
        return keyID
    }

    static func checksumsRoot(from bundleData: Data) throws -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: bundleData) as? [String: Any],
            let root = obj["checksums_root"] as? String
        else {
            throw VoiceIntentError.malformedJSON(path: bundlePath, reason: "checksums_root absent")
        }
        return root
    }
}
