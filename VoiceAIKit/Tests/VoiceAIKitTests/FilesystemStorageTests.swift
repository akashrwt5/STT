import XCTest
@testable import VoiceAIKit

final class FilesystemStorageTests: XCTestCase {
    
    var fileManager: FileManager!
    var tempBaseURL: URL!
    var storage: PackStorageController!
    
    override func setUp() {
        super.setUp()
        fileManager = .default
        tempBaseURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = try! PackStorageController(baseStorageURL: tempBaseURL, fileManager: fileManager)
    }
    
    override func tearDown() {
        try? fileManager.removeItem(at: tempBaseURL)
        super.tearDown()
    }
    
    func testStagingDirectoryCreation() throws {
        let stagingURL = try storage.stagingDirectory(for: "en", clean: true)
        
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: stagingURL.path, isDirectory: &isDirectory)
        
        XCTAssertTrue(exists)
        XCTAssertTrue(isDirectory.boolValue)
    }
    
    func testAtomicActivationAndCleanup() throws {
        // 1. Create staging and put a file in it
        let stagingURL = try storage.stagingDirectory(for: "en", clean: true)
        let dummyFile = stagingURL.appendingPathComponent("bundle.json")
        try "{}".write(to: dummyFile, atomically: true, encoding: .utf8)
        
        // 2. Commit and activate version 1.0.0
        try storage.commitStagingAndActivate(version: "1.0.0", for: "en")
        
        // 3. Verify 'Current' symlink exists and points correctly
        let currentPackURL = storage.currentPack(for: "en")
        XCTAssertNotNil(currentPackURL)
        XCTAssertTrue(fileManager.fileExists(atPath: currentPackURL!.appendingPathComponent("bundle.json").path))
        
        // Verify staging is removed by cleanup
        XCTAssertFalse(fileManager.fileExists(atPath: stagingURL.path))
    }
    
    func testRollbackRestoresPreviousVersion() throws {
        // Setup v1.0.0
        let staging1 = try storage.stagingDirectory(for: "en", clean: true)
        try "v1".write(to: staging1.appendingPathComponent("bundle.json"), atomically: true, encoding: .utf8)
        try storage.commitStagingAndActivate(version: "1.0.0", for: "en")
        
        // Setup v2.0.0
        let staging2 = try storage.stagingDirectory(for: "en", clean: true)
        try "v2".write(to: staging2.appendingPathComponent("bundle.json"), atomically: true, encoding: .utf8)
        try storage.commitStagingAndActivate(version: "2.0.0", for: "en")
        
        // Verify v2 is active
        var activeContent = try String(contentsOf: storage.currentPack(for: "en")!.appendingPathComponent("bundle.json"))
        XCTAssertEqual(activeContent, "v2")
        
        // Rollback
        try storage.rollback(for: "en")
        
        // Verify v1 is active
        activeContent = try String(contentsOf: storage.currentPack(for: "en")!.appendingPathComponent("bundle.json"))
        XCTAssertEqual(activeContent, "v1")
    }
}
