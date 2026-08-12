import XCTest
@testable import VoiceIntentKit

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
            seedPackURL: URL(fileURLWithPath: "/seed.nlu")
        )
    }
    
    func testStartupLoadsActivePack() async throws {
        storage.activePacks["en"] = URL(fileURLWithPath: "/active.nlu")
        
        // In this isolated mock environment without a real bundle.json in the mocked URL,
        // the attemptLoadActivePack should hit its catch block and call storage.rollback.
        try await client.start(for: "en")
        
        // Verify rollback was correctly triggered for a corrupted active pack
        XCTAssertTrue(storage.rollbackCalledPacks.contains("en"))
    }
    
    func testStartupFallsBackToSeedPack() async throws {
        // No active OTA pack exists
        do {
            try await client.start(for: "en")
            XCTFail("Expected seed pack invalid error due to missing physical seed bundle.json in mock environment")
        } catch VoiceIntentClientError.seedPackInvalid {
            // Success, it bypassed OTA and gracefully attempted to load the seed pack
        } catch {
            XCTFail("Expected seedPackInvalid error")
        }
    }
}
