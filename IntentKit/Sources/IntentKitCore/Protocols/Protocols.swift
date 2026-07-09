// Protocols.swift
// IntentKitCore
//
// One protocol per pipeline stage — each with a single responsibility. Concrete
// implementations live either in IntentKitCore (pure-Swift defaults) or in a
// backend module (IntentKitCoreML / IntentKitONNX). The pipeline depends ONLY on
// these abstractions (Dependency Inversion).

import Foundation

// MARK: - Text stages

/// Cheap, model-independent cleanup (trim, strip control/zero-width chars).
public protocol TextPreprocessor: Sendable {
    func preprocess(_ text: String, locale: Locale) -> String
}

/// Deterministic normalization: Unicode NFC, case folding, contraction/number/unit canonicalization.
public protocol TextNormalizer: Sendable {
    func normalize(_ text: String, locale: Locale) -> String
}

/// Text → tokens with retained character spans.
public protocol Tokenizer: Sendable {
    func tokenize(_ text: String, locale: Locale) -> [Token]
}

// MARK: - Inference stages

/// Tokens/text → a fixed-length embedding vector.
public protocol EmbeddingProvider: Sendable {
    var dimension: Int { get }
    func embed(tokens: [Token], originalText: String, locale: Locale) async throws -> Embedding
}

/// Embedding → raw logits over the intent label set. The ONLY stage that touches
/// the ML runtime; swapping Core ML ↔ ONNX changes nothing else.
public protocol IntentClassifierBackend: Sendable {
    var labels: [Intent] { get }
    func predict(_ embedding: Embedding) async throws -> [IntentLogit]
}

/// Raw logits → calibrated probabilities (softmax / temperature / Platt).
public protocol ConfidenceCalibrator: Sendable {
    func calibrate(_ logits: [IntentLogit]) -> [IntentCandidate]
}

// MARK: - Decision + context + output

/// Calibrated candidates (+ context) → a single verdict. Owns thresholds, margins,
/// and out-of-distribution / unknown handling. Business config lives here, not in the model.
public protocol DecisionPolicy: Sendable {
    func decide(_ candidates: [IntentCandidate], context: ConversationContext) -> IntentDecision
}

/// Optional conversation-state management (follow-ups, slot carry-over).
public protocol ContextManager: Sendable {
    /// Adjust/re-rank candidates using prior turns (e.g. bias toward plausible follow-ups).
    func enrich(_ candidates: [IntentCandidate], context: ConversationContext) -> [IntentCandidate]
}

/// Slot/entity extraction, label→domain mapping, output shaping.
public protocol IntentPostProcessor: Sendable {
    func postProcess(decision: IntentDecision, tokens: [Token], originalText: String) -> (decision: IntentDecision, slots: [String: String])
}

// MARK: - Model supply

/// Locates, loads, versions, and caches model + label/vocab assets.
public protocol ModelProvider: Sendable {
    var modelVersion: String { get }
    var labels: [Intent] { get }
}
