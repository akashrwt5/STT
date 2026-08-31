import XCTest
@testable import VoiceAIKit

final class MockPackExtractor: PackExtractor, @unchecked Sendable {
    var shouldThrowError: Error?
    var didExtractSource: URL?
    var didExtractDestination: URL?

    func extract(from source: URL, to destination: URL) throws {
        if let shouldThrowError { throw shouldThrowError }
        didExtractSource = source
        didExtractDestination = destination
    }
}

/// Structural / negative-path tests for the current `PackValidator`, which delegates its trust
/// chain to `PackIntegrity`. These cover the failures reachable BEFORE the cryptographic chain
/// (extraction, missing bundle.json).
///
/// NOTE: The signature failures still require a fully signed pack fixture (an ed25519 signature
/// over `integrity/manifest.sha256` ‖ `bundle.json` with the private key). Generating that is a
/// follow-up; those cases are intentionally not asserted here rather than asserted incorrectly.
/// The positive path and the provenance refusal ARE covered below, against the real seed pack —
/// signature verification skipped, every other link in the chain (checksums_root binding, per-file
/// digests, no-unsigned-files sweep) exercised for real.
final class PackValidatorTests: XCTestCase {

    var fileManager: FileManager!
    var extractor: MockPackExtractor!
    var validator: PackValidator!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        fileManager = .default
        extractor = MockPackExtractor()
        validator = PackValidator(fileManager: fileManager, extractor: extractor, trust: .unverifiedForTesting)
        tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDir)
        super.tearDown()
    }

    func testExtractionFailureThrowsError() {
        extractor.shouldThrowError = NSError(domain: "Test", code: 1)
        XCTAssertThrowsError(try validator.extractAndValidate(from: URL(fileURLWithPath: "/test.zip"), into: tempDir)) { error in
            guard case PackValidator.ValidationError.extractionFailed = error else {
                return XCTFail("Expected extractionFailed, got \(error)")
            }
        }
    }

    func testMissingBundleJSONThrowsError() {
        // Extraction "succeeds" but writes nothing, so bundle.json is absent.
        XCTAssertThrowsError(try validator.extractAndValidate(from: URL(fileURLWithPath: "/test.zip"), into: tempDir)) { error in
            guard case PackValidator.ValidationError.missingBundleJSON = error else {
                return XCTFail("Expected missingBundleJSON, got \(error)")
            }
        }
    }

    // MARK: - Provenance (VIK-034)

    /// The seed pack is dev-signed (`channel: "dev"`, `key_id: "dev-key-golden"`), which is the
    /// premise the two tests below rest on. Asserted rather than assumed: if a future pack ships
    /// on the production channel these tests would still pass while testing nothing.
    func testSeedPackIsADevelopmentPack() throws {
        let bundle = try seedBundle()
        XCTAssertEqual(bundle.channel, "dev")
        XCTAssertEqual(bundle.signatureInfo.keyID, "dev-key-golden")
        XCTAssertTrue(bundle.isDevelopmentPack)
    }

    /// A production trust policy must refuse a dev pack HERE — at prepare, before it is staged —
    /// not later, at session load, after it has already replaced the pack that worked.
    ///
    /// Before VIK-034 this could not be done at all: the OTA path decoded a manifest model with no
    /// `channel` field, so the installer had nothing to ask.
    func testDevelopmentPackIsRefusedAtValidation() throws {
        let source = try PackTestSupport.packRoot()
        let validator = PackValidator(fileManager: fileManager,
                                      extractor: CopyingPackExtractor(),
                                      trust: PackTrustPolicy(refusesDevelopmentPacks: true,
                                                             skipsSignatureVerification: true))

        XCTAssertThrowsError(try validator.extractAndValidate(from: source, into: tempDir)) { error in
            guard case PackValidator.ValidationError.developmentPackRefused(let channel, let keyID) = error else {
                return XCTFail("Expected developmentPackRefused, got \(error)")
            }
            XCTAssertEqual(channel, "dev")
            XCTAssertEqual(keyID, "dev-key-golden")
        }
    }

    /// The same pack, admitted by a policy that allows dev packs — so the test above is measuring
    /// the policy, not a pack that fails for some other reason. Also the validator's first
    /// positive-path assertion: it returns a `PackIdentity` carrying the pack's own fields.
    func testDevelopmentPackIsAdmittedWhenThePolicyAllowsIt() throws {
        let source = try PackTestSupport.packRoot()
        let validator = PackValidator(fileManager: fileManager,
                                      extractor: CopyingPackExtractor(),
                                      trust: .unverifiedForTesting)

        let identity = try validator.extractAndValidate(from: source, into: tempDir)
        let bundle = try seedBundle()

        XCTAssertEqual(identity.bundleID, bundle.bundleID)
        XCTAssertEqual(identity.version, bundle.version)
        XCTAssertEqual(identity.checksumRoot, bundle.checksumsRoot)
        XCTAssertEqual(identity.channel, "dev")
        XCTAssertEqual(identity.keyID, "dev-key-golden")
        XCTAssertEqual(identity.languages, ["en"])
    }

    private func seedBundle() throws -> NLUBundle {
        let data = try Data(contentsOf: PackTestSupport.packRoot().appendingPathComponent("bundle.json"))
        return try JSONDecoder().decode(NLUBundle.self, from: data)
    }
}

/// Extractor that copies a pack DIRECTORY into staging, standing in for unzipping an archive.
/// The tests above need the real pack's bytes in staging so `PackIntegrity.verify` has something
/// to verify; what produced them is irrelevant to what is being asserted.
final class CopyingPackExtractor: PackExtractor, @unchecked Sendable {
    func extract(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }
}
