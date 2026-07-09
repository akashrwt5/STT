// CoreModels.swift
// IntentKitCore
//
// The value types that flow through the NLU pipeline. All Sendable so they can
// cross the actor boundary freely.

import Foundation

// MARK: - Input

/// An immutable classification request. Text may originate from STT, a keyboard,
/// a share sheet, or any other source — the pipeline does not care.
public struct NLURequest: Sendable {
    public let text: String
    public let locale: Locale
    public let timestamp: Date
    public let context: ConversationContext

    public init(
        text: String,
        locale: Locale = .current,
        timestamp: Date = Date(),
        context: ConversationContext = .empty
    ) {
        self.text = text
        self.locale = locale
        self.timestamp = timestamp
        self.context = context
    }
}

// MARK: - Intermediate artifacts

/// A single token plus its character range in the ORIGINAL text (spans are retained
/// so post-processing can map extracted entities back to what the user actually said).
public struct Token: Sendable, Hashable {
    public let text: String
    public let range: Range<String.Index>
    public init(text: String, range: Range<String.Index>) {
        self.text = text
        self.range = range
    }
}

/// A fixed-length dense vector — the only representation the classifier head sees.
public struct Embedding: Sendable {
    public let values: [Float]
    public var dimension: Int { values.count }
    public init(values: [Float]) { self.values = values }
}

/// A raw (uncalibrated) score for one intent label, straight from the model head.
public struct IntentLogit: Sendable {
    public let intent: Intent
    public let score: Double
    public init(intent: Intent, score: Double) {
        self.intent = intent
        self.score = score
    }
}

// MARK: - Output

public struct Intent: Sendable, Hashable {
    public let name: String       // canonical label, e.g. "adjust_volume"
    public let domain: String?    // optional grouping, e.g. "audio_control"
    public init(name: String, domain: String? = nil) {
        self.name = name
        self.domain = domain
    }
}

public struct IntentCandidate: Sendable {
    public let intent: Intent
    public let confidence: Double   // calibrated 0...1
    public init(intent: Intent, confidence: Double) {
        self.intent = intent
        self.confidence = confidence
    }
}

public enum RejectionReason: Sendable, Equatable {
    case emptyInput
    case lowConfidence
    case outOfScope
    case ambiguousBelowMargin
}

/// The verdict. The classifier proposes a distribution; the DecisionPolicy chooses
/// exactly one of these three cases.
public enum IntentDecision: Sendable {
    case recognized(Intent, confidence: Double)
    case ambiguous([IntentCandidate])
    case unknown(RejectionReason)
}

/// The public result returned to the consuming app.
public struct IntentResult: Sendable {
    public let decision: IntentDecision
    public let alternatives: [IntentCandidate]  // ranked runners-up (observability / disambiguation)
    public let slots: [String: String]          // extracted entities
    public let locale: Locale
    public let latency: Duration

    public init(
        decision: IntentDecision,
        alternatives: [IntentCandidate] = [],
        slots: [String: String] = [:],
        locale: Locale,
        latency: Duration = .zero
    ) {
        self.decision = decision
        self.alternatives = alternatives
        self.slots = slots
        self.locale = locale
        self.latency = latency
    }
}

// MARK: - Context

public struct ConversationTurn: Sendable {
    public let utterance: String
    public let intent: Intent?
    public let slots: [String: String]
    public let timestamp: Date
    public init(utterance: String, intent: Intent?, slots: [String: String] = [:], timestamp: Date = Date()) {
        self.utterance = utterance
        self.intent = intent
        self.slots = slots
        self.timestamp = timestamp
    }
}

/// A bounded, immutable snapshot of conversation state passed into a request.
public struct ConversationContext: Sendable {
    public let turns: [ConversationTurn]
    public static let empty = ConversationContext(turns: [])
    public init(turns: [ConversationTurn]) { self.turns = turns }
    public var lastIntent: Intent? { turns.last?.intent }
}
