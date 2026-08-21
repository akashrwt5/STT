import Foundation
@testable import VoiceAIKit

/// Mock validator matching the current `PackValidating` protocol
/// (`currentRuntimeContract` + `extractAndValidate(from:into:)`).
///
/// On success it writes a complete, strictly-decodable `bundle.json` into the staging directory
/// (so the installer's C8 token guard, which re-reads that file, is satisfied) and returns the
/// `PackIdentity` derived from those same bytes.
///
/// The JSON below carries EVERY field `NLUBundle` requires, including the four the deleted
/// `NLUPackManifest` did not model (`channel`, `compiler_version`, `required_runtime_features`,
/// `telemetry_schema_version`). That is deliberate: the old mock could produce a document the
/// real loader would have rejected, which is how a mock stops testing anything.
public final class MockPackValidator: PackValidating, @unchecked Sendable {

    public var shouldThrowError: Error?
    /// The version the produced manifest / bundle.json will carry.
    public var mockVersion: String = "1.0.0"
    /// The `checksums_root` the produced bundle.json will carry. The C8 token guard matches on
    /// this, so a test can simulate "staging was rebuilt with a different pack" by changing it.
    public var mockChecksumsRoot: String = "deadbeef"
    /// `"production"` so the default `PackTrustPolicy` admits it. Set to `"dev"` to exercise
    /// `PackValidator`'s refusal path in a test that uses the real validator.
    public var mockChannel: String = "production"
    public private(set) var validateCallCount = 0

    public let currentRuntimeContract = 1

    public init() {}

    public func extractAndValidate(from packageURL: URL, into stagingDirectory: URL) throws -> PackIdentity {
        validateCallCount += 1
        if let shouldThrowError { throw shouldThrowError }

        let data = Self.bundleJSON(version: mockVersion,
                                   checksumsRoot: mockChecksumsRoot,
                                   channel: mockChannel)

        // Mimic extraction: leave a decodable bundle.json in staging for the token guard.
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try data.write(to: stagingDirectory.appendingPathComponent("bundle.json"))

        let bundle = try JSONDecoder().decode(NLUBundle.self, from: data)
        return PackIdentity(bundle)
    }

    /// A complete `bundle.json`, exposed so a test can plant a DIFFERENT well-formed one in
    /// staging and exercise the C8 token guard on its own terms — rather than planting malformed
    /// JSON, which the guard rejects for the wrong reason (it fails to decode at all).
    public static func bundleJSON(version: String,
                                  checksumsRoot: String,
                                  channel: String = "production") -> Data {
        Data("""
        {
          "bundle_id": "pack-en-v\(version)",
          "version": "\(version)",
          "format_version": "3.0",
          "content_version": 1,
          "compiler_version": "nlu-compiler 1.0.0-test",
          "channel": "\(channel)",
          "created_at": "2026-01-01T00:00:00Z",
          "checksums_root": "\(checksumsRoot)",
          "telemetry_schema_version": 1,
          "engine_compat": { "min_runtime_contract": 1, "max_tested_runtime_contract": 1 },
          "required_runtime_features": [],
          "signature_info": { "scheme": "ed25519-v1", "key_id": "prod-key-1" },
          "languages": { "en": { "status": "full" } },
          "capabilities": {},
          "models": {
            "intent": {
              "en": {
                "artifact": "models/intent/en/model.onnx",
                "coreml_compiled_artifact": "models/intent/en/model.mlmodelc",
                "format": "onnx",
                "model_version": "en-\(version)"
              }
            }
          },
          "report_card_summary": { "gates_passed": "true" }
        }
        """.utf8)
    }
}
