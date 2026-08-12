import Foundation
@testable import VoiceIntentKit

/// Mock storage matching the current `PackStorageControlling` protocol.
///
/// It is backed by a real temporary directory so that `stagingDirectory(for:clean:)` returns a
/// usable path — the installer writes/reads a real `bundle.json` there for its C8 token guard and
/// hands the same path to the engine's smoke test.
public final class MockPackStorageController: PackStorageControlling, @unchecked Sendable {

    public let baseURL: URL

    // In-memory state
    public var activePacks: [String: URL] = [:]
    public var rollbackCalledPacks: Set<String> = []

    // Tracking
    public var commitCallCount = 0
    public var activateCallCount = 0
    public var rollbackCallCount = 0

    /// Set to make `rollback` throw (simulating "no previous version").
    public var rollbackError: Error?

    public init() {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MockPackStorage_\(UUID().uuidString)", isDirectory: true)
    }

    private func languageDir(_ language: String) throws -> URL {
        let url = baseURL.appendingPathComponent(language, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func stagingDirectory(for language: String, clean: Bool) throws -> URL {
        let staging = try languageDir(language).appendingPathComponent("staging", isDirectory: true)
        if clean, FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    public func currentPack(for language: String) -> URL? { activePacks[language] }

    public func hasActivePack(for language: String) -> Bool { activePacks[language] != nil }

    public func commitStagingAndActivate(version: String, for language: String) throws {
        commitCallCount += 1
        // Simulate promoting staging → active by pointing the active URL at the staging content.
        let staging = try stagingDirectory(for: language, clean: false)
        activePacks[language] = staging
    }

    public func activate(version: String, for language: String) throws {
        activateCallCount += 1
    }

    public func rollback(for language: String) throws {
        rollbackCallCount += 1
        rollbackCalledPacks.insert(language)
        if let rollbackError { throw rollbackError }
        activePacks.removeValue(forKey: language)
    }
}
