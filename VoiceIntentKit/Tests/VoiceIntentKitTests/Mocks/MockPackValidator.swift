import Foundation
@testable import VoiceIntentKit

public class MockPackValidator: PackValidating {
    
    // Configuration for test scenarios
    public var shouldThrowError: Error?
    
    // Default manifest to return
    public var mockManifest = NLUPackManifest(
        bundleId: "com.starkey.test",
        formatVersion: "3.0",
        version: "1.0.0",
        engineCompatibility: .init(minimumVersion: "1.0.0", testedVersions: ["1.0.0"]),
        runtimeContract: .init(version: "1.0"),
        signature: .init(algorithm: "Ed25519", publicKey: "mock", signature: "mock"),
        models: [
            "intent": [
                "en": .init(
                    coremlCompiledArtifact: "model.mlmodelc",
                    vocabularyArtifact: "vocab.txt"
                )
            ]
        ],
        capabilities: ["intents", "slots"]
    )
    
    // Tracking assertions
    public var validateCallCount = 0
    
    public init() {}
    
    public func validate(stagedPackURL: URL) async throws -> NLUPackManifest {
        validateCallCount += 1
        
        if let error = shouldThrowError {
            throw error
        }
        
        return mockManifest
    }
}
