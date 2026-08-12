import Foundation

/// Protocol allowing the Host App to inject their preferred ZIP extraction library (e.g., ZIPFoundation).
/// This keeps VoiceIntentKit a thin SDK without forcing 3rd party dependencies.
public protocol PackExtractor {
    /// Extracts the package from the source URL into the destination URL.
    func extract(from source: URL, to destination: URL) throws
}

public protocol PackValidating {
    var currentRuntimeContract: Int { get }
    func extractAndValidate(from packageURL: URL, into stagingDirectory: URL) throws -> NLUPackManifest
}

/// Responsible for extracting the OTA package, parsing the manifest, and verifying its
/// integrity and authenticity.
///
/// The trust chain itself is NOT reimplemented here — it delegates to `PackIntegrity.verify`,
/// the same Ed25519 + sha256 chain the live `VoiceIntentSession` runs when it loads a pack. That
/// makes OTA validation and session load use ONE verifier and ONE `PackTrustPolicy`, instead of
/// the two divergent implementations that existed before (this class used to bypass signatures
/// when a key was absent and had an empty checksum stub).
public final class PackValidator: PackValidating {

    public enum ValidationError: Error, LocalizedError {
        case extractionFailed(Error)
        case missingBundleJSON
        case invalidBundleJSON(Error)
        case unsupportedFormatVersion(String)
        case incompatibleEngine(required: Int, current: Int)
        case integrityCheckFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .extractionFailed(let e): return "Failed to extract package: \(e.localizedDescription)"
            case .missingBundleJSON: return "The package does not contain a bundle.json file."
            case .invalidBundleJSON(let e): return "Failed to parse bundle.json: \(e.localizedDescription)"
            case .unsupportedFormatVersion(let v): return "Unsupported format version: \(v)."
            case .incompatibleEngine(let required, let current): return "Incompatible engine. Required: \(required), Current: \(current)."
            case .integrityCheckFailed(let e): return "Package integrity/authenticity verification failed: \(e.localizedDescription)"
            }
        }
    }

    private let fileManager: FileManager
    private let extractor: PackExtractor

    /// The current runtime contract of the VoiceIntentKit engine.
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

    /// Extracts the package and validates its structure, compatibility, integrity, and authenticity.
    /// - Returns: The parsed and verified `NLUPackManifest`, decoded from the exact bytes that were
    ///   covered by the signature.
    public func extractAndValidate(from packageURL: URL, into stagingDirectory: URL) throws -> NLUPackManifest {
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
        //    re-reading the file.
        let manifest: NLUPackManifest
        do {
            manifest = try JSONDecoder().decode(NLUPackManifest.self, from: verified.bundleJSONBytes)
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

        return manifest
    }
}
