import Foundation
@testable import VoiceIntentKit

public class MockNLUEngineProvider: NLUEngineProvider {
    
    // Configuration for test scenarios
    public var shouldThrowError: Error?
    
    // Controllable state
    public var internalIsIdle: Bool = true
    
    // Tracking assertions
    public var loadCallCount = 0
    public var loadedModelPath: URL?
    public var loadedVocabularyPath: URL?
    
    public init() {}
    
    public var isIdle: Bool {
        return internalIsIdle
    }
    
    public func load(modelPath: URL, vocabularyPath: URL) throws {
        loadCallCount += 1
        
        if let error = shouldThrowError {
            throw error
        }
        
        loadedModelPath = modelPath
        loadedVocabularyPath = vocabularyPath
    }
}
