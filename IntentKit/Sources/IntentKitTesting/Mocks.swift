// Mocks.swift
// IntentKitTesting
//
// Test doubles + fixtures, mirroring the STT module's MockAudioInputProvider style.
// Because IntentKitCore has no ML dependency, the whole pipeline tests with these —
// no .mlmodel file required in CI.

import Foundation
import IntentKitCore

/// A deterministic backend: returns whatever logits you seed it with.
public struct MockClassifierBackend: IntentClassifierBackend {
    public let labels: [Intent]
    private let scores: [Double]
    public init(labels: [Intent], scores: [Double]) {
        precondition(labels.count == scores.count, "labels/scores length mismatch")
        self.labels = labels
        self.scores = scores
    }
    public func predict(_ embedding: Embedding) async throws -> [IntentLogit] {
        zip(labels, scores).map { IntentLogit(intent: $0.0, score: $0.1) }
    }
}

/// Returns a constant embedding — the mock backend ignores it anyway.
public struct MockEmbeddingProvider: EmbeddingProvider {
    public let dimension: Int
    public init(dimension: Int = 8) { self.dimension = dimension }
    public func embed(tokens: [Token], originalText: String, locale: Locale) async throws -> Embedding {
        Embedding(values: [Float](repeating: 0.1, count: dimension))
    }
}

public enum FixtureIntents {
    public static let volumeUp = Intent(name: "adjust_volume", domain: "audio_control")
    public static let mute = Intent(name: "mute", domain: "audio_control")
    public static let program = Intent(name: "change_program", domain: "audio_control")
    public static let all: [Intent] = [volumeUp, mute, program]
}
