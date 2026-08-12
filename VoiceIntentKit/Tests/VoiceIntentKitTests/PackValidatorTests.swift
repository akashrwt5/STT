import XCTest
@testable import VoiceIntentKit

final class MockPackExtractor: PackExtractor {
    var shouldThrowError: Error?
    var didExtractSource: URL?
    var didExtractDestination: URL?
    
    func extract(from source: URL, to destination: URL) throws {
        if let error = shouldThrowError {
            throw error
        }
        didExtractSource = source
        didExtractDestination = destination
    }
}

final class PackValidatorTests: XCTestCase {
    
    var fileManager: FileManager!
    var extractor: MockPackExtractor!
    var validator: PackValidator!
    var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        fileManager = .default
        extractor = MockPackExtractor()
        validator = PackValidator(fileManager: fileManager, extractor: extractor)
        tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
    }
    
    override func tearDown() {
        try? fileManager.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testExtractionFailureThrowsError() {
        extractor.shouldThrowError = NSError(domain: "Test", code: 1, userInfo: nil)
        
        XCTAssertThrowsError(try validator.extractAndValidate(from: URL(fileURLWithPath: "/test.zip"), into: tempDir)) { error in
            guard case PackValidator.ValidationError.extractionFailed = error else {
                XCTFail("Expected extractionFailed error")
                return
            }
        }
    }
    
    func testMissingBundleJSONThrowsError() {
        // Extraction succeeds, but there's no bundle.json in tempDir
        XCTAssertThrowsError(try validator.extractAndValidate(from: URL(fileURLWithPath: "/test.zip"), into: tempDir)) { error in
            guard case PackValidator.ValidationError.missingBundleJSON = error else {
                XCTFail("Expected missingBundleJSON error")
                return
            }
        }
    }
    
    func testValidBundleJSONSucceeds() throws {
        // Create a valid bundle.json
        let json = """
        {
            "bundle_id": "test",
            "format_version": "3.0",
            "version": "1.0",
            "engine_compat": { "min_runtime_contract": 1, "tested_versions": [] },
            "runtime_contract": { "version": "1.0" },
            "signature": { "scheme": "none", "public_key": "", "signature": "" },
            "models": {
                "intent": {
                    "en": { "artifact": "model.mlmodelc" }
                }
            },
            "capabilities": []
        }
        """
        
        let bundleURL = tempDir.appendingPathComponent("bundle.json")
        try json.write(to: bundleURL, atomically: true, encoding: .utf8)
        
        let modelURL = tempDir.appendingPathComponent("model.mlmodelc")
        try Data().write(to: modelURL)
        
        let manifest = try validator.extractAndValidate(from: URL(fileURLWithPath: "/test.zip"), into: tempDir)
        XCTAssertEqual(manifest.version, "1.0")
    }
    
    func testUnsupportedFormatVersionThrowsError() throws {
        let json = """
        {
            "bundle_id": "test",
            "format_version": "2.0",
            "version": "1.0",
            "engine_compat": { "min_runtime_contract": 1, "tested_versions": [] },
            "runtime_contract": { "version": "1.0" },
            "signature": { "scheme": "none", "public_key": "", "signature": "" },
            "models": {},
            "capabilities": []
        }
        """
        
        let bundleURL = tempDir.appendingPathComponent("bundle.json")
        try json.write(to: bundleURL, atomically: true, encoding: .utf8)
        
        XCTAssertThrowsError(try validator.extractAndValidate(from: URL(fileURLWithPath: "/test.zip"), into: tempDir)) { error in
            guard case PackValidator.ValidationError.unsupportedFormatVersion = error else {
                XCTFail("Expected unsupportedFormatVersion error")
                return
            }
        }
    }
    
    func testMissingRequiredArtifactThrowsError() throws {
        let json = """
        {
            "bundle_id": "test",
            "format_version": "3.0",
            "version": "1.0",
            "engine_compat": { "min_runtime_contract": 1, "tested_versions": [] },
            "runtime_contract": { "version": "1.0" },
            "signature": { "scheme": "none", "public_key": "", "signature": "" },
            "models": {
                "intent": {
                    "en": { "artifact": "missing_model.mlmodelc" }
                }
            },
            "capabilities": []
        }
        """
        
        let bundleURL = tempDir.appendingPathComponent("bundle.json")
        try json.write(to: bundleURL, atomically: true, encoding: .utf8)
        
        // Don't create the artifact file
        
        XCTAssertThrowsError(try validator.extractAndValidate(from: URL(fileURLWithPath: "/test.zip"), into: tempDir)) { error in
            guard case PackValidator.ValidationError.missingRequiredArtifact = error else {
                XCTFail("Expected missingRequiredArtifact error")
                return
            }
        }
    }
}
