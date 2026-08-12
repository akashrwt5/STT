import Foundation
@testable import VoiceIntentKit

public class MockPackStorageController: PackStorageControlling {
    
    // In-memory state simulation
    public var activePacks: [String: URL] = [:]
    public var stagingPacks: [String: URL] = [:]
    public var rollbackCalledPacks: Set<String> = []
    
    // Tracking for assertions
    public var cleanupStagingCallCount = 0
    public var cleanupObsoleteCallCount = 0
    public var activateCallCount = 0
    public var initializeCallCount = 0
    
    public init() {}
    
    public func currentPack(for language: String) -> URL? {
        return activePacks[language]
    }
    
    public func stagingDirectory(for language: String) -> URL {
        // Return a virtual or temporary URL for testing
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mock_staging_\(language)")
        stagingPacks[language] = url
        return url
    }
    
    public func hasActivePack(for language: String) -> Bool {
        return activePacks[language] != nil
    }
    
    public func activateStagedPack(for language: String) throws {
        activateCallCount += 1
        if let stagedURL = stagingPacks[language] {
            activePacks[language] = stagedURL // "Activate" it by moving it to active
            stagingPacks.removeValue(forKey: language)
        }
    }
    
    public func rollback(for language: String) throws {
        rollbackCalledPacks.insert(language)
        // In a real scenario, this restores the 'previous' symlink.
        // For mocks, we can just clear the active pack or simulate a revert if needed.
        activePacks.removeValue(forKey: language)
    }
    
    public func cleanupStaging(for language: String) throws {
        cleanupStagingCallCount += 1
        stagingPacks.removeValue(forKey: language)
    }
    
    public func cleanupObsoleteVersions(for language: String) throws {
        cleanupObsoleteCallCount += 1
    }
    
    public func initializeStorage() throws {
        initializeCallCount += 1
    }
}
