import XCTest
@testable import VoiceAIKit

final class VoiceIntentClientTests: XCTestCase {

    var storage: MockPackStorageController!
    var validator: MockPackValidator!
    var engine: MockNLUEngineProvider!
    var client: VoiceIntentClient!

    override func setUp() {
        super.setUp()
        storage = MockPackStorageController()
        validator = MockPackValidator()
        engine = MockNLUEngineProvider()
        client = VoiceIntentClient(
            storage: storage,
            validator: validator,
            engineProvider: engine,
            seedPackURL: URL(fileURLWithPath: "/nonexistent-seed")
        )
    }

    /// No OTA pack → start bypasses OTA and attempts the seed, which is absent in this mock env,
    /// so it surfaces `seedPackInvalid` (never a silent success on the wrong data).
    func testStartupFallsBackToSeedPack() async {
        do {
            try await client.start(for: "en")
            XCTFail("Expected seedPackInvalid because the mock seed has no bundle.json")
        } catch VoiceIntentClientError.seedPackInvalid {
            // expected
        } catch {
            XCTFail("Expected seedPackInvalid, got \(error)")
        }
    }

    /// A corrupt active OTA pack triggers a rollback, then falls through to the seed.
    func testCorruptActivePackTriggersRollback() async {
        storage.activePacks["en"] = URL(fileURLWithPath: "/nonexistent-active")
        do {
            try await client.start(for: "en")
            XCTFail("Expected seedPackInvalid after rollback")
        } catch VoiceIntentClientError.seedPackInvalid {
            XCTAssertTrue(storage.rollbackCalledPacks.contains("en"), "A corrupt pack must trigger rollback")
        } catch {
            XCTFail("Expected seedPackInvalid, got \(error)")
        }
    }

    /// C6: even when rollback itself fails (no previous version), start() must NOT throw the rollback
    /// error past the seed — the seed pack is the guaranteed floor. So we still see `seedPackInvalid`,
    /// never a `PackStorageError`.
    func testRollbackFailureStillFallsThroughToSeed() async {
        storage.activePacks["en"] = URL(fileURLWithPath: "/nonexistent-active")
        storage.rollbackError = PackStorageError.noPreviousVersionAvailable

        do {
            try await client.start(for: "en")
            XCTFail("Expected seedPackInvalid")
        } catch VoiceIntentClientError.seedPackInvalid {
            // expected — the rollback failure did not escape past the seed fallback
        } catch {
            XCTFail("A rollback failure must not propagate past the seed floor; got \(error)")
        }
    }
}
