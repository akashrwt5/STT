import Foundation

/// Protocol allowing the Host App to inject their preferred ZIP extraction library (e.g., ZIPFoundation).
/// This keeps VoiceAIKit a thin SDK without forcing 3rd party dependencies.
public protocol PackExtractor: Sendable {
    /// Extracts the package from the source URL into the destination URL.
    func extract(from source: URL, to destination: URL) throws
}

public protocol PackValidating: Sendable {
    var currentRuntimeContract: Int { get }
    /// Extracts, verifies and admits a downloaded pack.
    ///
    /// Returns `PackIdentity` — the same type a live `VoiceIntentSession` reports as
    /// `loadedPack`, so "what did the installer admit?" and "what is running?" are answered in
    /// one vocabulary instead of two. The full manifest stays internal: a host has no business
    /// reading `bundle.json`'s shape, and the type that let it do so is what made VIK-035
    /// (decode → modify → re-encode → broken signature) possible.
    func extractAndValidate(from packageURL: URL, into stagingDirectory: URL) throws -> PackIdentity
}

/// Responsible for extracting the OTA package, parsing the manifest, and verifying its
/// integrity and authenticity.
///
/// The trust chain itself is NOT reimplemented here — it delegates to `PackIntegrity.verify`,
/// the same Ed25519 + sha256 chain the live `VoiceIntentSession` runs when it loads a pack. That
/// makes OTA validation and session load use ONE verifier and ONE `PackTrustPolicy`, instead of
/// the two divergent implementations that existed before (this class used to bypass signatures
/// when a key was absent and had an empty checksum stub).
/// Every stored property is an immutable `let`, so the `Sendable` conformance is checked rather
/// than asserted. The one exception is marked at the property itself.
public final class PackValidator: PackValidating {

    public enum ValidationError: Error, LocalizedError {
        case extractionFailed(Error)
        case missingBundleJSON
        case invalidBundleJSON(Error)
        case unsupportedFormatVersion(String)
        case incompatibleEngine(required: Int, current: Int)
        case integrityCheckFailed(Error)
        /// The pack is authentic but was not signed for production, and this trust policy
        /// refuses those. Distinct from `integrityCheckFailed` — the signature was GOOD; the
        /// question is who holds the key, not whether the bytes are intact.
        case developmentPackRefused(channel: String, keyID: String)

        public var errorDescription: String? {
            switch self {
            case .extractionFailed(let e): return "Failed to extract package: \(e.localizedDescription)"
            case .missingBundleJSON: return "The package does not contain a bundle.json file."
            case .invalidBundleJSON(let e): return "Failed to parse bundle.json: \(e.localizedDescription)"
            case .unsupportedFormatVersion(let v): return "Unsupported format version: \(v)."
            case .incompatibleEngine(let required, let current): return "Incompatible engine. Required: \(required), Current: \(current)."
            case .integrityCheckFailed(let e): return "Package integrity/authenticity verification failed: \(e.localizedDescription)"
            case .developmentPackRefused(let channel, let keyID):
                return "Refusing a non-production pack: channel '\(channel)', key '\(keyID)'."
            }
        }
    }

    /// `FileManager` is not `Sendable`, though its methods are documented as safe to call from
    /// multiple threads when no `FileManagerDelegate` is set, which is the case here.
    nonisolated(unsafe) private let fileManager: FileManager
    private let extractor: PackExtractor

    /// The current runtime contract of the VoiceAIKit engine.
    /// This should be bumped when breaking changes are made to inference logic.
    public let currentRuntimeContract = 1

    /// Who is allowed to have signed an OTA pack, and how strict to be. Required — there is no
    /// nil bypass. Pass `.unverifiedForTesting` explicitly (dev builds only) to skip signatures;
    /// a production trust policy has `refusesDevelopmentPacks == true`, which makes the skip path
    /// unreachable.
    private let trust: PackTrustPolicy
    private let loadPolicy: PackLoadPolicy

    public init(fileManager: FileManager = .default,
                extractor: PackExtractor,
                trust: PackTrustPolicy,
                loadPolicy: PackLoadPolicy = .default) {
        self.fileManager = fileManager
        self.extractor = extractor
        self.trust = trust
        self.loadPolicy = loadPolicy
    }

    /// Extracts the package and validates its structure, compatibility, integrity, authenticity
    /// and provenance.
    /// - Returns: The identity of the verified pack, derived from the exact bytes the signature
    ///   covered.
    public func extractAndValidate(from packageURL: URL, into stagingDirectory: URL) throws -> PackIdentity {
        // 1. Extraction
        do {
            try extractor.extract(from: packageURL, to: stagingDirectory)
        } catch {
            throw ValidationError.extractionFailed(error)
        }

        // 2. Verify bundle.json exists
        let bundleURL = stagingDirectory.appendingPathComponent("bundle.json")
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw ValidationError.missingBundleJSON
        }

        // 3. FULL trust chain — Ed25519 signature, checksums_root binding, every-file digest, and
        //    a no-unsigned-files sweep. Mandatory. Throws on the first failure.
        let verified: PackIntegrity.Verified
        do {
            verified = try PackIntegrity.verify(packRoot: stagingDirectory, trust: trust, policy: loadPolicy)
        } catch {
            throw ValidationError.integrityCheckFailed(error)
        }

        // 4. Parse the manifest from the VERIFIED bytes (provably what was signed), not by
        //    re-reading the file. `NLUBundle` is the ONE model of `bundle.json` — the same type
        //    `BundleDataLoader` decodes on the session path, so the installer and the session
        //    can no longer hold different beliefs about the same file (VIK-034).
        let manifest: NLUBundle
        do {
            manifest = try JSONDecoder().decode(NLUBundle.self, from: verified.bundleJSONBytes)
        } catch {
            throw ValidationError.invalidBundleJSON(error)
        }

        // 5. Format & engine compatibility.
        guard manifest.formatVersion.starts(with: "3.") else {
            throw ValidationError.unsupportedFormatVersion(manifest.formatVersion)
        }
        guard currentRuntimeContract >= manifest.engineCompat.minRuntimeContract else {
            throw ValidationError.incompatibleEngine(required: manifest.engineCompat.minRuntimeContract,
                                                     current: currentRuntimeContract)
        }

        // 6. Provenance — refuse a dev-signed or non-production pack HERE, at validation.
        //
        // The bytes are already sitting in the staging directory by this point (step 1 put them
        // there), but staging is scratch space: `preparePack` never reaches `.readyToActivate`,
        // no `PackIdentity` is cached, and the next prepare wipes the directory. Nothing the user
        // relies on has been touched.
        //
        // `BundleDataLoader` runs the same check on the session path and keeps running it: a pack
        // can reach disk without passing through this installer (the bundled seed pack does), so
        // the session-load check is not redundant. What changes is WHEN the OTA path finds out.
        //
        // Until now the installer decoded a manifest model with no `channel` field at all, so it
        // could not ask; a dev pack was downloaded, verified, staged and activated, and the
        // refusal arrived at the next session load — after the good pack had already been
        // replaced, with rollback as the only way back.
        if trust.refusesDevelopmentPacks && manifest.isDevelopmentPack {
            throw ValidationError.developmentPackRefused(channel: manifest.channel,
                                                         keyID: manifest.signatureInfo.keyID)
        }

        return PackIdentity(manifest)
    }
}
