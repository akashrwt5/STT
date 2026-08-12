import XCTest
@testable import VoiceIntentKit

final class MockPackExtractor: PackExtractor {
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
/// NOTE: The positive path and the signature/checksum failures require a fully signed pack fixture
/// (ed25519 signature over `integrity/manifest.sha256` ‖ `bundle.json`, a matching `checksums_root`,
/// and per-file digests). Generating that fixture is a follow-up; those cases are intentionally not
/// asserted here rather than asserted incorrectly.
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
}
