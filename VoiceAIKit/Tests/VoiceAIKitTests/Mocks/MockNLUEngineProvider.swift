import Foundation
@testable import VoiceAIKit

/// Mock engine provider matching the current `NLUEngineProvider` protocol
/// (`isIdle`, `load`, and the async `smokeTest(packRoot:language:)`).
public final class MockNLUEngineProvider: NLUEngineProvider, @unchecked Sendable {

    // Configuration for test scenarios
    public var smokeTestError: Error?
    public var loadError: Error?
    public var internalIsIdle: Bool = true

    // Tracking assertions
    public var loadCallCount = 0
    public var smokeTestCallCount = 0
    public var lastSmokeTestPackRoot: URL?
    public var lastSmokeTestLanguage: String?

    public init() {}

    public var isIdle: Bool { internalIsIdle }

    public func load(modelPath: URL, vocabularyPath: URL) throws {
        loadCallCount += 1
        if let loadError { throw loadError }
    }

    public func smokeTest(packRoot: URL, language: String) async throws {
        smokeTestCallCount += 1
        lastSmokeTestPackRoot = packRoot
        lastSmokeTestLanguage = language
        if let smokeTestError { throw smokeTestError }
    }
}
