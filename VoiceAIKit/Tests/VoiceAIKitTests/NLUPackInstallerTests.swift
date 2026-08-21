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
        let identity = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")
        XCTAssertEqual(identity.version, "1.0.0")
        XCTAssertEqual(installer.stagingState, .readyToActivate)

        // The fields the OTA path was structurally blind to before VIK-034: the manifest model it
        // decoded had no `channel` and no `compiler_version`, so the installer could not have
        // reported — or refused on — either one.
        XCTAssertEqual(identity.channel, "production")
        XCTAssertEqual(identity.compilerVersion, "nlu-compiler 1.0.0-test")
        XCTAssertEqual(identity.bundleID, "pack-en-v1.0.0")
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

    /// C8: if the staging bundle.json no longer matches the prepared pack (staging rebuilt),
    /// activation must refuse rather than activate a mismatched pack.
    func testActivateRefusesWhenStagingHoldsUnreadableJSON() async throws {
        _ = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")

        let staging = try storage.stagingDirectory(for: "en", clean: false)
        try Data(#"{"version":"9.9.9"}"#.utf8).write(to: staging.appendingPathComponent("bundle.json"))

        await assertRefusesActivation()
    }

    /// The token guard matches on `checksums_root`, NOT on `version`.
    ///
    /// This is the case the old assertion could not distinguish. Here staging holds a perfectly
    /// well-formed `bundle.json` carrying the SAME version string as the prepared pack and a
    /// different `checksums_root` — i.e. a different build wearing the same label, which is what
    /// "staging was wiped and rebuilt" actually looks like when a version is re-cut. Matching on
    /// the version admits it; matching on the digest the signature covers does not.
    func testActivateRefusesWhenStagingHoldsDifferentBytesUnderTheSameVersion() async throws {
        _ = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")

        let staging = try storage.stagingDirectory(for: "en", clean: false)
        let impostor = MockPackValidator.bundleJSON(version: validator.mockVersion,
                                                    checksumsRoot: "0000000000000000")
        XCTAssertNotEqual(validator.mockChecksumsRoot, "0000000000000000",
                          "Premise: the impostor must differ from the prepared pack's root")
        try impostor.write(to: staging.appendingPathComponent("bundle.json"))

        await assertRefusesActivation()
    }

    /// The same well-formed bundle.json that WAS prepared still activates — so the assertion above
    /// is testing the digest comparison, not merely that a rewritten file is rejected.
    func testActivateSucceedsWhenStagingStillHoldsThePreparedPack() async throws {
        _ = try await installer.preparePack(from: URL(fileURLWithPath: "/test.zip"), language: "en")

        let staging = try storage.stagingDirectory(for: "en", clean: false)
        let same = MockPackValidator.bundleJSON(version: validator.mockVersion,
                                                checksumsRoot: validator.mockChecksumsRoot)
        try same.write(to: staging.appendingPathComponent("bundle.json"))

        try await installer.activatePreparedPack(language: "en")
        XCTAssertEqual(storage.commitCallCount, 1)
        XCTAssertEqual(installer.stagingState, .active)
    }

    private func assertRefusesActivation(file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await installer.activatePreparedPack(language: "en")
            XCTFail("Expected activation to refuse a mismatched staging pack", file: file, line: line)
        } catch {
            guard case InstallerError.invalidStateForActivation = error else {
                return XCTFail("Expected invalidStateForActivation, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(storage.commitCallCount, 0, file: file, line: line)
        }
    }
}
