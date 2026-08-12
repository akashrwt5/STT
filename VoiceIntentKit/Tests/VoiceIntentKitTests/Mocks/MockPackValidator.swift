import Foundation
@testable import VoiceIntentKit

/// Mock validator matching the current `PackValidating` protocol
/// (`currentRuntimeContract` + `extractAndValidate(from:into:)`).
///
/// On success it writes a minimal, decodable `bundle.json` into the staging directory (so the
/// installer's C8 token guard, which re-reads that file, is satisfied) and returns the manifest
/// decoded from those same bytes.
public final class MockPackValidator: PackValidating {

    public var shouldThrowError: Error?
    /// The version the produced manifest / bundle.json will carry.
    public var mockVersion: String = "1.0.0"
    public private(set) var validateCallCount = 0

    public let currentRuntimeContract = 1

    public init() {}

    public func extractAndValidate(from packageURL: URL, into stagingDirectory: URL) throws -> NLUPackManifest {
        validateCallCount += 1
        if let shouldThrowError { throw shouldThrowError }

        let json = """
        {
          "bundle_id": "pack-en-test",
          "version": "\(mockVersion)",
          "format_version": "3.0",
          "content_version": 1,
          "engine_compat": { "min_runtime_contract": 1 },
          "checksums_root": "deadbeef",
          "signature_info": { "scheme": "ed25519-v1", "key_id": "dev-key-golden" },
          "created_at": "2026-01-01T00:00:00Z",
          "languages": { "en": { "status": "full" } },
          "models": {
            "intent": {
              "en": {
                "artifact": "models/intent/en/model.onnx",
                "vocabulary_artifact": "models/intent/en/vocab.txt",
                "coreml_compiled_artifact": "models/intent/en/model.mlmodelc",
                "format": "coreml",
                "model_version": "en-\(mockVersion)"
              }
            }
          },
          "capabilities": {}
        }
        """
        let data = Data(json.utf8)

        // Mimic extraction: leave a decodable bundle.json in staging for the token guard.
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try data.write(to: stagingDirectory.appendingPathComponent("bundle.json"))

        return try JSONDecoder().decode(NLUPackManifest.self, from: data)
    }
}
