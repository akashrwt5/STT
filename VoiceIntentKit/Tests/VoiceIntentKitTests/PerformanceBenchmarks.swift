import XCTest
@testable import VoiceIntentKit

final class PerformanceBenchmarks: XCTestCase {
    
    var fileManager: FileManager!
    var tempDir: URL!
    var storage: PackStorageController!
    
    override func setUp() {
        super.setUp()
        fileManager = .default
        tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = try! PackStorageController(baseStorageURL: tempDir, fileManager: fileManager)
    }
    
    override func tearDown() {
        try? fileManager.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testAtomicActivationPerformance() throws {
        // Setup staging
        let stagingURL = try storage.stagingDirectory(for: "en", clean: true)
        let dummyFile = stagingURL.appendingPathComponent("bundle.json")
        try "{}".write(to: dummyFile, atomically: true, encoding: .utf8)
        
        measure {
            // Measure the time it takes to atomically rename a directory and update a symlink
            try? storage.commitStagingAndActivate(version: "1.0.\(UUID().uuidString)", for: "en")
            
            // Re-setup staging for the next iteration of `measure`
            let newStagingURL = try? storage.stagingDirectory(for: "en", clean: true)
            try? "{}".write(to: newStagingURL!.appendingPathComponent("bundle.json"), atomically: true, encoding: .utf8)
        }
    }
}
