// DefaultStages.swift
// IntentKitCore
//
// Pure-Swift default implementations of the pipeline stages. No ML dependency, so
// these unit-test instantly. Backends (embedding / classification) live elsewhere.

import Foundation

// MARK: - Preprocessing

public struct DefaultTextPreprocessor: TextPreprocessor {
    public init() {}
    public func preprocess(_ text: String, locale: Locale) -> String {
        // Trim, collapse whitespace, strip control + zero-width characters.
        let stripped = text.unicodeScalars.filter { scalar in
            !scalar.properties.isDefaultIgnorableCodePoint &&
            !CharacterSet.controlCharacters.contains(scalar)
        }
        let collapsed = String(String.UnicodeScalarView(stripped))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Normalization

public struct UnicodeTextNormalizer: TextNormalizer {
    private let contractions: [String: String]
    public init(contractions: [String: String] = UnicodeTextNormalizer.defaultContractions) {
        self.contractions = contractions
    }
    public func normalize(_ text: String, locale: Locale) -> String {
        // NFC + locale-aware case fold.
        var s = text.precomposedStringWithCanonicalMapping.lowercased(with: locale)
        // Expand common contractions (word-boundary safe, simple default set).
        for (k, v) in contractions {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s
    }
    public static let defaultContractions: [String: String] = [
        "won't": "will not", "can't": "cannot", "n't": " not",
        "'re": " are", "'ll": " will", "'ve": " have", "'m": " am"
    ]
}

// MARK: - Tokenization (Foundation-only default; NL-based variant lives in the CoreML target)

public struct SimpleWordTokenizer: Tokenizer {
    public init() {}
    public func tokenize(_ text: String, locale: Locale) -> [Token] {
        var tokens: [Token] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.byWords, .localized]) { sub, range, _, _ in
            if let sub, !sub.isEmpty { tokens.append(Token(text: sub, range: range)) }
        }
        return tokens
    }
}

// MARK: - Calibration

/// Numerically-stable softmax with a temperature term. Temperature > 1 softens
/// overconfident heads so thresholds tune predictably.
public struct SoftmaxCalibrator: ConfidenceCalibrator {
    public let temperature: Double
    public init(temperature: Double = 1.0) { self.temperature = max(0.0001, temperature) }
    public func calibrate(_ logits: [IntentLogit]) -> [IntentCandidate] {
        guard let maxScore = logits.map(\.score).max() else { return [] }
        let exps = logits.map { exp(($0.score - maxScore) / temperature) }
        let sum = exps.reduce(0, +)
        guard sum > 0 else { return logits.map { IntentCandidate(intent: $0.intent, confidence: 0) } }
        return zip(logits, exps).map { IntentCandidate(intent: $0.0.intent, confidence: $0.1 / sum) }
    }
}

// MARK: - Decision policy

/// Threshold + margin + entropy-based out-of-distribution detection.
public struct ThresholdMarginPolicy: DecisionPolicy {
    public let acceptThreshold: Double     // τ_accept
    public let marginThreshold: Double     // τ_margin
    public let maxEntropyRatio: Double     // reject if normalized entropy exceeds this (near-uniform ⇒ OOD)

    public init(acceptThreshold: Double = 0.6, marginThreshold: Double = 0.15, maxEntropyRatio: Double = 0.9) {
        self.acceptThreshold = acceptThreshold
        self.marginThreshold = marginThreshold
        self.maxEntropyRatio = maxEntropyRatio
    }

    public func decide(_ candidates: [IntentCandidate], context: ConversationContext) -> IntentDecision {
        let ranked = candidates.sorted { $0.confidence > $1.confidence }
        guard let top = ranked.first else { return .unknown(.lowConfidence) }

        // Out-of-distribution: a near-uniform distribution matches nothing.
        if normalizedEntropy(ranked) > maxEntropyRatio { return .unknown(.outOfScope) }

        // Absolute confidence floor.
        guard top.confidence >= acceptThreshold else { return .unknown(.lowConfidence) }

        // Margin over the runner-up.
        let second = ranked.dropFirst().first?.confidence ?? 0
        guard (top.confidence - second) >= marginThreshold else {
            return .ambiguous(Array(ranked.prefix(2)))
        }
        return .recognized(top.intent, confidence: top.confidence)
    }

    private func normalizedEntropy(_ candidates: [IntentCandidate]) -> Double {
        let n = candidates.count
        guard n > 1 else { return 0 }
        let h = candidates.reduce(0.0) { acc, c in
            c.confidence > 0 ? acc - c.confidence * log(c.confidence) : acc
        }
        return h / log(Double(n))   // 0 = certain, 1 = uniform
    }
}

// MARK: - Context managers

/// No-op — single-turn apps pay nothing.
public struct StatelessContextManager: ContextManager {
    public init() {}
    public func enrich(_ candidates: [IntentCandidate], context: ConversationContext) -> [IntentCandidate] {
        candidates
    }
}

// MARK: - Post-processing

/// Default: passes the decision through, extracts no slots. Compose real extractors
/// behind IntentPostProcessor for entity extraction.
public struct PassthroughPostProcessor: IntentPostProcessor {
    public init() {}
    public func postProcess(decision: IntentDecision, tokens: [Token], originalText: String) -> (decision: IntentDecision, slots: [String: String]) {
        (decision, [:])
    }
}
