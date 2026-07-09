// NLEmbeddingProvider.swift
// IntentKitCoreML
//
// Sentence embeddings via Apple's NaturalLanguage framework — on-device, no model
// file to ship for the embedding step. Swap for a Core ML sentence encoder when a
// domain-tuned embedding is available.

import Foundation
import NaturalLanguage
import IntentKitCore

public struct NLEmbeddingProvider: EmbeddingProvider {
    public let dimension: Int
    private let language: NLLanguage

    /// - Parameter language: Language for the embedding space. Defaults to English.
    public init(language: NLLanguage = .english) {
        self.language = language
        // NLEmbedding vector dimension is model-defined; probe once, fall back to 300.
        self.dimension = NLEmbedding.sentenceEmbedding(for: language)?.dimension ?? 300
    }

    public func embed(tokens: [Token], originalText: String, locale: Locale) async throws -> Embedding {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            throw IntentKitError.embeddingUnavailable(language.rawValue)
        }
        // Prefer the normalized token stream; fall back to the original text.
        let sentence = tokens.isEmpty ? originalText : tokens.map(\.text).joined(separator: " ")
        guard let vector = embedding.vector(for: sentence) else {
            // Out-of-vocabulary sentence → zero vector; the policy will treat it as OOD.
            return Embedding(values: [Float](repeating: 0, count: dimension))
        }
        return Embedding(values: vector.map(Float.init))
    }
}

public enum IntentKitError: Error, Sendable {
    case embeddingUnavailable(String)
    case modelNotFound(String)
    case labelSchemaMismatch(expected: Int, actual: Int)
}
