// NLUEngine.swift
// STT
//
// The orchestrator that replaces Dialogflow end-to-end, on-device.
// Mirrors IntentClassifier/scripts/nlu/engine.py.
//
// Per-turn priority order:
//   1. CONFIRMATION — an active yes/no follow-up context
//   2. SLOT FILLING — a mid-collection intent
//   3. CLASSIFY     — a fresh turn
//
// Thread-safety: a single NLUEngine instance is driven from one conversation
// (the live transcription view model) on the main actor. Heavy classification
// is delegated to IntentClassifierService, which is itself thread-safe.

import Foundation

public final class NLUEngine: @unchecked Sendable {

    private let schema: NLUSchema
    private let classifier: IntentClassifierService
    private let entities: EntityExtractor
    private let session: NLUSession
    private let affirmative: Set<String>
    private let negative: Set<String>

    public init(
        schema: NLUSchema = .loadFromBundle(),
        classifier: IntentClassifierService = .shared,
        entities: EntityExtractor = EntityExtractor(),
        sessionID: String = "default"
    ) {
        self.schema = schema
        self.classifier = classifier
        self.entities = entities
        self.session = NLUSession(sessionID: sessionID)
        self.affirmative = Set(schema.affirmative)
        self.negative = Set(schema.negative)
    }

    // MARK: - Public API

    /// Processes one user utterance and returns the next conversational step.
    /// Async because Stage 3 (semantic rescue) runs CoreML inference.
    public func handle(_ text: String) async -> NLUResponse {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let confirm = activeConfirmation() {
            return handleConfirmation(confirm.intent, confirm.followup, text)
        }
        if session.pendingIntent != nil {
            return handleSlotFilling(text)
        }
        return await handleNewIntent(text)
    }

    /// Abandons any in-progress conversation (slot filling / confirmation).
    public func reset() {
        session.resetAll()
    }

    /// True when the engine is mid-conversation and the next utterance is an answer.
    public var isCollecting: Bool {
        session.pendingIntent != nil || activeConfirmation() != nil
    }

    // MARK: - Confirmation (priority 1)

    private func activeConfirmation() -> (intent: String, followup: FollowupDef)? {
        for (name, cfg) in schema.intents {
            if let fu = cfg.followup, session.hasContext(fu.context) {
                return (name, fu)
            }
        }
        return nil
    }

    private func handleConfirmation(_ intent: String, _ fu: FollowupDef, _ text: String) -> NLUResponse {
        switch yesNo(text) {
        case .none:
            // Re-arm the context and ask again.
            session.setContext(fu.context, lifespan: fu.lifespan)
            return .confirm(intent: intent, action: nil, question: fu.prompt)
        case .some(let yes):
            session.clearContext(fu.context)
            let branch = yes ? fu.yes : fu.no
            return .fulfill(intent: intent, action: branch.action,
                            parameters: [:], message: branch.fulfillment, confidence: 1.0)
        }
    }

    private static let uncertain = ["not sure", "maybe", "dunno", "don't know",
                                    "dont know", "i don't know", "no idea", "unsure"]

    /// Returns true for yes, false for no, nil for ambiguous/uncertain.
    private func yesNo(_ text: String) -> Bool? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if Self.uncertain.contains(where: { t.contains($0) }) { return nil }
        let neg = negative.contains { wholeWord($0, in: t) }
        let pos = affirmative.contains { wholeWord($0, in: t) }
        if neg && !pos { return false }
        if pos && !neg { return true }
        if neg && pos  { return false }   // negation wins on conflict
        return nil
    }

    // MARK: - Slot filling (priority 2)

    private func handleSlotFilling(_ text: String) -> NLUResponse {
        guard let intent = session.pendingIntent, let cfg = schema.intents[intent] else {
            session.resetSlotFilling()
            return handleNewIntent(text)
        }

        // The utterance answers the slot we last prompted for.
        if let awaiting = session.awaitingSlot,
           let slot = cfg.slots.first(where: { $0.name == awaiting }) {
            var value = entities.extract(slot.entity, from: text)
            // Open free-text slots (e.g. @remind) accept the raw answer as a fallback.
            if value == nil && slot.entity == "remind" {
                value = text.trimmingCharacters(in: .whitespaces)
            }
            if let value { session.pendingSlots[slot.name] = value }
        }

        // Opportunistically fill any other slots mentioned in the same answer.
        extractAllSlots(cfg, text, into: &session.pendingSlots)
        return advanceSlots(intent, cfg)
    }

    private func advanceSlots(_ intent: String, _ cfg: IntentDef) -> NLUResponse {
        for slot in cfg.slots where slot.required && session.pendingSlots[slot.name] == nil {
            session.pendingIntent = intent
            session.awaitingSlot = slot.name
            return .prompt(intent: intent, question: slot.prompt, filled: session.pendingSlots)
        }
        let params = session.pendingSlots
        session.resetSlotFilling()
        return .fulfill(intent: intent, action: cfg.action,
                        parameters: params, message: cfg.fulfillment ?? "", confidence: 1.0)
    }

    // MARK: - New intent (priority 3)

    private func handleNewIntent(_ text: String) async -> NLUResponse {
        session.decrementContexts()
        let result = await classifier.classifyAsync(text)
        let intent = result.label
        let conf   = result.confidence

        if intent == "OUT_OF_SCOPE" || intent == "Default Fallback Intent" || conf < schema.confidenceThreshold {
            return .fallback(url: classifier.genaiURL(for: text), confidence: conf)
        }
        let rescued = result.semanticRescue

        guard let cfg = schema.intents[intent] else {
            // Intent recognized but has no schema config — simple single-turn, no slot filling.
            return .fulfill(intent: intent, action: nil, parameters: [:], message: "", confidence: conf, semanticRescue: rescued)
        }

        // Intent that opens with a yes/no confirmation (e.g. Cmd.SendMessage).
        if let fu = cfg.followup {
            session.setContext(fu.context, lifespan: fu.lifespan)
            return .confirm(intent: intent, action: cfg.action, question: fu.prompt)
        }

        // Intent that needs slots — extract what we can from this first utterance.
        if !cfg.slots.isEmpty {
            var slots: [String: String] = [:]
            extractAllSlots(cfg, text, into: &slots)
            fillOpenTopics(cfg, text, into: &slots)
            session.pendingIntent = intent
            session.pendingSlots = slots
            session.awaitingSlot = nil
            return advanceSlots(intent, cfg)
        }

        // Simple single-turn intent.
        return .fulfill(intent: intent, action: cfg.action,
                        parameters: [:], message: cfg.fulfillment ?? "", confidence: conf, semanticRescue: rescued)
    }

    // MARK: - Slot extraction helpers

    private func extractAllSlots(_ cfg: IntentDef, _ text: String, into slots: inout [String: String]) {
        for slot in cfg.slots where slots[slot.name] == nil {
            if let value = entities.extract(slot.entity, from: text) {
                slots[slot.name] = value
            }
        }
    }

    /// Carrier phrases stripped to derive an open topic (e.g. "remind me to " → "").
    private static let carrierPatterns: [String] = [
        #"^\s*please\s+"#,
        #"^\s*(?:do\s*n[o']?t|don't|dont)\s+let\s+me\s+forget\b\s*(?:to|about)?\s*"#,
        #"^\s*(?:remind|tell|alert|notify)\s+me\b\s*(?:to|that|about|of)?\s*"#,
        #"^\s*set(?:\s+up)?\s+(?:a\s+)?reminder\b\s*(?:to|for|about)?\s*"#,
        #"^\s*make\s+sure\s+(?:i|to)\b\s*"#,
        #"^\s*i\s+(?:need|have|want)\s+to\b\s*"#,
    ]

    /// For required "open" slots not yet filled, derive a free-text topic from the utterance.
    private func fillOpenTopics(_ cfg: IntentDef, _ text: String, into slots: inout [String: String]) {
        for slot in cfg.slots {
            guard slots[slot.name] == nil, slot.required, entities.isOpen(slot.entity) else { continue }
            if let topic = deriveTopic(text), !topic.isEmpty {
                slots[slot.name] = topic
            }
        }
    }

    private func deriveTopic(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces)
        for pattern in Self.carrierPatterns {
            if let range = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                t.removeSubrange(range)
                break
            }
        }
        let stripped = entities.stripDateTime(t)
        return stripped.isEmpty ? nil : stripped
    }

    // MARK: - Misc

    private func wholeWord(_ word: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return text.range(of: "\\b\(escaped)\\b", options: .regularExpression) != nil
    }
}
