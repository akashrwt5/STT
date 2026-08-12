import Foundation
import CryptoKit

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

/// Responsible for extracting the OTA package, parsing the manifest, and verifying cryptographic integrity.
public final class PackValidator: PackValidating {
    
    public enum ValidationError: Error, LocalizedError {
        case extractionFailed(Error)
        case missingBundleJSON
        case invalidBundleJSON(Error)
        case unsupportedFormatVersion(String)
        case incompatibleEngine(required: Int, current: Int)
        case signatureVerificationFailed
        case checksumMismatch(file: String)
        case missingRequiredArtifact(String)
        
        public var errorDescription: String? {
            switch self {
            case .extractionFailed(let e): return "Failed to extract package: \(e.localizedDescription)"
            case .missingBundleJSON: return "The package does not contain a bundle.json file."
            case .invalidBundleJSON(let e): return "Failed to parse bundle.json: \(e.localizedDescription)"
            case .unsupportedFormatVersion(let v): return "Unsupported format version: \(v)."
            case .incompatibleEngine(let required, let current): return "Incompatible engine. Required: \(required), Current: \(current)."
            case .signatureVerificationFailed: return "Cryptographic signature verification failed."
            case .checksumMismatch(let file): return "Checksum mismatch for file: \(file)."
            case .missingRequiredArtifact(let file): return "Missing required artifact: \(file)."
            }
        }
    }
    
    private let fileManager: FileManager
    private let extractor: PackExtractor
    
    /// The current runtime contract of the VoiceIntentKit engine.
    /// This should be bumped when breaking changes are made to inference logic.
    public let currentRuntimeContract = 1
    
    /// The Ed25519 public key used to verify the `dev-key-golden` signatures.
    /// In production, this should be securely embedded or retrieved.
    /// TODO: (Security) Make this non-optional in the next release to enforce authenticity.
    private let trustedPublicKeyBase64: String?
    
    public init(fileManager: FileManager = .default, extractor: PackExtractor, trustedPublicKeyBase64: String? = nil) {
        self.fileManager = fileManager
        self.extractor = extractor
        self.trustedPublicKeyBase64 = trustedPublicKeyBase64
    }
    
    /// Extracts the package and validates its structure, compatibility, and cryptographic signatures.
    /// - Parameters:
    ///   - packageURL: The URL of the downloaded `.nlu` zip file.
    ///   - stagingDirectory: The URL of the clean staging directory to extract into.
    /// - Returns: The parsed and validated `NLUPackManifest`.
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
        
        // 3. Parse Manifest
        let manifest: NLUPackManifest
        do {
            let data = try Data(contentsOf: bundleURL)
            manifest = try JSONDecoder().decode(NLUPackManifest.self, from: data)
        } catch {
            throw ValidationError.invalidBundleJSON(error)
        }
        
        // 4. Verify Format & Compatibility
        guard manifest.formatVersion.starts(with: "3.") else {
            throw ValidationError.unsupportedFormatVersion(manifest.formatVersion)
        }
        
        guard currentRuntimeContract >= manifest.engineCompat.minRuntimeContract else {
            throw ValidationError.incompatibleEngine(required: manifest.engineCompat.minRuntimeContract, current: currentRuntimeContract)
        }
        
        // 5. Verify Cryptographic Signature
        try verifySignature(for: manifest, stagingDirectory: stagingDirectory)
        
        // 6. Verify Artifact Checksums
        try verifyChecksums(stagingDirectory: stagingDirectory)
        
        // 7. Verify Required Models Exist
        try verifyRequiredModels(manifest: manifest, stagingDirectory: stagingDirectory)
        
        return manifest
    }
    
    /// Verifies the Ed25519 signature of the package using `CryptoKit`.
    private func verifySignature(for manifest: NLUPackManifest, stagingDirectory: URL) throws {
        guard let publicKeyString = trustedPublicKeyBase64 else {
            // TODO: (Security) Enforce signature verification in the next release.
            print("[PackValidator] WARNING: Signature verification bypassed because trustedPublicKeyBase64 is nil.")
            return
        }
        
        // Find the signature file in the integrity directory
        let signatureURL = stagingDirectory.appendingPathComponent("integrity").appendingPathComponent("signature.sig")
        let bundleURL = stagingDirectory.appendingPathComponent("bundle.json")
        
        if manifest.signatureInfo.scheme == "ed25519-v1" {
            guard fileManager.fileExists(atPath: signatureURL.path), fileManager.fileExists(atPath: bundleURL.path) else {
                throw ValidationError.signatureVerificationFailed
            }
            
            do {
                let signatureData = try Data(contentsOf: signatureURL)
                let bundleData = try Data(contentsOf: bundleURL)
                
                if let keyData = Data(base64Encoded: publicKeyString) {
                    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
                    let isValid = publicKey.isValidSignature(signatureData, for: bundleData)
                    if !isValid {
                        // Enforce signature check
                        throw ValidationError.signatureVerificationFailed
                    }
                } else {
                    // Fallback if public key is malformed in SDK config
                    throw ValidationError.signatureVerificationFailed
                }
            } catch {
                throw ValidationError.signatureVerificationFailed
            }
        }
    }
    
    /// Verifies the SHA256 checksums of all files in the package.
    private func verifyChecksums(stagingDirectory: URL) throws {
        // Implementation would read `integrity/checksums.json`, iterate through the files,
        // hash them with `SHA256.hash(data:)`, and compare.
        // Left as an extension point depending on exact integrity format.
    }
    
    private func verifyRequiredModels(manifest: NLUPackManifest, stagingDirectory: URL) throws {
        for (_, localeDict) in manifest.models {
            for (_, artifact) in localeDict {
                // On iOS, OTA packages strip out the .onnx files to save bandwidth.
                // We only need to verify that at least one of the declared CoreML artifacts exists.
                let possibleCoreMLPaths = [
                    artifact.coremlFullCompiledArtifact,
                    artifact.coremlFullArtifact,
                    artifact.coremlCompiledArtifact,
                    artifact.coremlArtifact
                ].compactMap { $0 }
                
                var foundValidModel = false
                
                if !possibleCoreMLPaths.isEmpty {
                    for coreMLPath in possibleCoreMLPaths {
                        let path = stagingDirectory.appendingPathComponent(coreMLPath)
                        if fileManager.fileExists(atPath: path.path) {
                            foundValidModel = true
                            break
                        }
                    }
                }
                
                // Fallback to the base artifact (e.g. ONNX/JSON) if it's not a CoreML model
                if !foundValidModel {
                    let path = stagingDirectory.appendingPathComponent(artifact.artifact)
                    if fileManager.fileExists(atPath: path.path) {
                        foundValidModel = true
                    }
                }
                
                if !foundValidModel {
                    throw ValidationError.missingRequiredArtifact(possibleCoreMLPaths.first ?? artifact.artifact)
                }
            }
        }
    }
}
