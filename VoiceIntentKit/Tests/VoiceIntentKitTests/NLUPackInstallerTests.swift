import XCTest
@testable import VoiceIntentKit

final class NLUPackInstallerTests: XCTestCase {
    
    var storage: MockPackStorageController!
    var validator: MockPackValidator!
    var engine: MockNLUEngineProvider!
    var installer: NLUPackInstaller!
    
    override func setUp() {
        super.setUp()
        storage = MockPackStorageController()
        validator = MockPackValidator()
        engine = MockNLUEngineProvider()
        installer = NLUPackInstaller(storage: storage, validator: validator, engineProvider: engine)
    }
    
    func testPreparePackSuccess() async throws {
        let manifest = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(installer.stagingState, .readyToActivate)
    }
    
    func testPreparePackValidationFailure() async {
        validator.shouldThrowError = PackValidator.ValidationError.missingBundleJSON
        
        do {
            _ = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")
            XCTFail("Expected preparation to fail")
        } catch {
            XCTAssertEqual(installer.stagingState, .failed)
            XCTAssertEqual(storage.cleanupStagingCallCount, 1)
        }
    }
    
    func testActivatePreparedPackSuccess() async throws {
        // Setup staging state
        _ = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")
        
        try await installer.activatePreparedPack(language: "en")
        
        XCTAssertEqual(storage.activateCallCount, 1)
        XCTAssertEqual(engine.loadCallCount, 1) // Smoke test
        XCTAssertEqual(storage.cleanupObsoleteCallCount, 1)
        XCTAssertEqual(installer.stagingState, .active)
    }
    
    func testActivateFailsIfEngineBusy() async throws {
        _ = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")
        engine.internalIsIdle = false
        
        do {
            try await installer.activatePreparedPack(language: "en")
            XCTFail("Expected failure due to busy engine")
        } catch {
            guard case NLUPackInstallerError.engineBusy = error else {
                XCTFail("Expected engineBusy error")
                return
            }
        }
    }
    
    func testActivateFailsIfSmokeTestFails() async throws {
        _ = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")
        engine.shouldThrowError = NSError(domain: "Test", code: 1, userInfo: nil)
        
        do {
            try await installer.activatePreparedPack(language: "en")
            XCTFail("Expected smoke test to fail")
        } catch {
            XCTAssertEqual(storage.activateCallCount, 0, "Activation should not occur if smoke test fails")
            XCTAssertEqual(installer.stagingState, .failed)
        }
    }
}
