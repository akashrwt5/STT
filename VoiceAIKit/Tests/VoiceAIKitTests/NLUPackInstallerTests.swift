import XCTest
@testable import VoiceAIKit

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

    func testPreparePackValidationFailurePropagates() async {
        validator.shouldThrowError = PackValidator.ValidationError.missingBundleJSON
        do {
            _ = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")
            XCTFail("Expected preparation to fail")
        } catch {
            XCTAssertNotEqual(installer.stagingState, .readyToActivate)
        }
    }

    func testActivatePreparedPackRunsSmokeTestThenCommits() async throws {
        _ = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")
        try await installer.activatePreparedPack(language: "en")

        XCTAssertEqual(engine.smokeTestCallCount, 1, "A real smoke test must run before activation")
        XCTAssertEqual(storage.commitCallCount, 1)
        XCTAssertEqual(installer.stagingState, .active)
    }

    func testActivateFailsIfEngineBusy() async throws {
        _ = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")
        engine.internalIsIdle = false

        do {
            try await installer.activatePreparedPack(language: "en")
            XCTFail("Expected failure due to busy engine")
        } catch {
            guard case InstallerError.activationFailedEngineNotIdle = error else {
                return XCTFail("Expected activationFailedEngineNotIdle, got \(error)")
            }
            XCTAssertEqual(storage.commitCallCount, 0)
            XCTAssertEqual(engine.smokeTestCallCount, 0)
        }
    }

    func testActivateFailsIfSmokeTestFails() async throws {
        _ = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")
        engine.smokeTestError = NSError(domain: "Test", code: 1)

        do {
            try await installer.activatePreparedPack(language: "en")
            XCTFail("Expected smoke test to fail")
        } catch {
            guard case InstallerError.smokeTestFailed = error else {
                return XCTFail("Expected smokeTestFailed, got \(error)")
            }
            XCTAssertEqual(storage.commitCallCount, 0, "A bad pack must never become Current")
            XCTAssertEqual(installer.stagingState, .failed)
        }
    }

    /// C8: if the staging bundle.json no longer matches the prepared manifest (staging rebuilt),
    /// activation must refuse rather than activate a mismatched pack.
    func testActivateRefusesOnStagingTokenMismatch() async throws {
        _ = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")

        // Corrupt the staging bundle.json so its version no longer matches the prepared manifest.
        let staging = try storage.stagingDirectory(for: "en", clean: false)
        try Data(#"{"version":"9.9.9"}"#.utf8).write(to: staging.appendingPathComponent("bundle.json"))

        do {
            try await installer.activatePreparedPack(language: "en")
            XCTFail("Expected activation to refuse a mismatched staging pack")
        } catch {
            guard case InstallerError.invalidStateForActivation = error else {
                return XCTFail("Expected invalidStateForActivation, got \(error)")
            }
            XCTAssertEqual(storage.commitCallCount, 0)
        }
    }
}
