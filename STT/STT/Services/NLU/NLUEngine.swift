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
// Thread-safety: `NLUEngine` is an `actor`. Its methods run on the actor's own
// serial executor (off the main thread), so heavy classification never blocks
// the UI and the engine's mutable session state is automatically serialised —
// no `@unchecked Sendable` and no manual `Task.detached` hop at the call site.
// Callers on the main actor reach it with `await nlu.handle(...)`, which hops
// off main for the duration of the call and back when it returns.

import Foundation

public actor NLUEngine {

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
            return await handleSlotFilling(text)
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

    /// Confidence required for a new intent to interrupt an in-progress slot flow.
    /// Higher than the base 0.70 to avoid abandoning a flow on an ambiguous answer.
    /// Mirrors Python NLUEngine.INTERRUPT_THRESHOLD = 0.75.
    private static let interruptThreshold: Double = 0.75

    private func handleSlotFilling(_ text: String) async -> NLUResponse {
        guard let intent = session.pendingIntent, let cfg = schema.intents[intent] else {
            session.resetSlotFilling()
            return await handleNewIntent(text)
        }

        // Re-classify every slot-filling turn. A different intent at high
        // confidence means the user switched topics — abandon the pending flow
        // and handle the new intent immediately (mirrors Python _handle_slot_filling).
        let probe = await classifier.classifyAsync(text)
        let isNewIntent = probe.label != intent
            && probe.label != "Default Fallback Intent"
            && probe.label != "OUT_OF_SCOPE"
            && probe.confidence >= Self.interruptThreshold
            && schema.intents[probe.label] != nil
        if isNewIntent {
            let abandoned = intent
            session.resetSlotFilling()
            let newResult = await handleNewIntent(text)
            return .interrupted(cancelledIntent: abandoned, result: newResult)
        }

        // The utterance answers the slot we last prompted for.
        let awaiting = session.awaitingSlot
        if let awaiting,
           let slot = cfg.slots.first(where: { $0.name == awaiting }) {
            if slot.entity == "sys.date-time" {
                let (iso, filled) = resolveDateTime(text)
                if filled, let iso { session.pendingSlots[slot.name] = iso }
            } else {
                var value = entities.extract(slot.entity, from: text)
                // Open free-text entities (e.g. @remind) accept the raw answer as a
                // fallback — a nil structured extraction is expected, not a failure.
                if value == nil && entities.isOpen(slot.entity) {
                    value = text.trimmingCharacters(in: .whitespaces)
                }
                if let value { session.pendingSlots[slot.name] = value }
            }
        }

        // Opportunistically fill OTHER slots mentioned in the same answer; skip the
        // slot we just handled so a parked date-time isn't re-resolved (and the day
        // double-advanced) by anchoring it to itself.
        extractAllSlots(cfg, text, into: &session.pendingSlots, skip: awaiting)
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
        let result  = await classifier.classifyAsync(text)
        let intent  = result.label
        let conf    = result.confidence
        let rescued = result.semanticRescue

        // Semantic rescue already passed its own 0.55 gate inside classifyAsync.
        // Do NOT re-apply Stage 2's 0.70 threshold to a semanticRescue result —
        // doing so would drop every rescue (rescue conf 0.55–0.69 → false fallback).
        let outOfScope = intent == "OUT_OF_SCOPE" || intent == "Default Fallback Intent"
        if !rescued && (outOfScope || conf < schema.confidenceThreshold) {
            return .fallback(url: await classifier.genaiURL(for: text), confidence: conf)
        }

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

    private func extractAllSlots(_ cfg: IntentDef, _ text: String,
                                 into slots: inout [String: String], skip: String? = nil) {
        for slot in cfg.slots where slots[slot.name] == nil && slot.name != skip {
            if slot.entity == "sys.date-time" {
                // Only fill when a time was actually given; a day-only mention
                // parks the day in session.partialDateTime and leaves the slot
                // open so the engine prompts for the time.
                let (iso, filled) = resolveDateTime(text)
                if filled, let iso { slots[slot.name] = iso }
                continue
            }
            if let value = entities.extract(slot.entity, from: text) {
                slots[slot.name] = value
            }
        }
    }

    /// Resolve a date-time slot value from `text`.
    ///
    /// Returns `filled == true` only when an explicit time was given. When the
    /// user supplies a day but no time, the resolved day is parked (at local
    /// midnight) in `session.partialDateTime` and `(nil, false)` is returned so
    /// the engine prompts for the time; a later bare-time answer ("3pm") is
    /// anchored to that parked day so "tomorrow" is not lost.
    private func resolveDateTime(_ text: String) -> (iso: String?, filled: Bool) {
        // Probe with the real clock first. This reveals whether the answer
        // carries its OWN day ("tomorrow at 9am") — in which case it wins and we
        // must NOT anchor, or the parked day would advance.
        guard var match = entities.extractDateTime(text, now: Date()) else {
            return (nil, false)
        }
        // Bare time with no day of its own — anchor it to the parked day so
        // "tomorrow" is preserved (resolve against that day's midnight).
        if !match.explicitDay,
           let parked = session.partialDateTime.flatMap({ Self.parseLocalISO($0) }),
           let anchored = entities.extractDateTime(text, now: parked) {
            match = anchored
        }
        if match.timeExplicit {
            session.partialDateTime = nil
            return (match.iso, true)
        }
        // Day given, no time — park the day at local midnight so a later answer
        // like "6am" stays on this day instead of rolling forward.
        if let day = Self.parseLocalISO(match.iso) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            session.partialDateTime = Self.formatLocalISO(cal.startOfDay(for: day))
        }
        return (nil, false)
    }

    // Local wall-clock ISO (no zone), matching EntityExtractor.isoMinutes.
    private static func localISOFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }
    private static func parseLocalISO(_ s: String) -> Date? { localISOFormatter().date(from: s) }
    private static func formatLocalISO(_ d: Date) -> String { localISOFormatter().string(from: d) }

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
