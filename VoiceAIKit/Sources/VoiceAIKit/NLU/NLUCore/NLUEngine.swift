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
import os.log

// Lifecycle tracing at `.debug`, which os_log does not emit unless someone turns it
// on — so it costs a host nothing and still answers "did this actually deallocate?".
// It was `print`, which a package has no business doing: it lands in the host app's
// console, unfiltered, with no subsystem to filter it out by.
private let lifecycleLog = Logger(subsystem: "com.voiceaikit", category: "Lifecycle")

actor NLUEngine: ConversationEngine {

    private let schema: NLUSchema
    // Depends on the abstraction, never a concrete classifier. `PackEngineFactory`
    // injects a `PackClassifierAdapter` over the pack's own head; the orchestration
    // body below is language-agnostic and never learns which language it is in.
    private let classifier: any IntentClassifying
    // Likewise an abstraction. `PackSlotResolver` is the only implementation now
    // that `EntityExtractor` — which read `nlu_entities.json` out of a bundle —
    // is gone. The protocol stays because it is what let the source of truth
    // change without rewriting the dialog logic below, and it is what a second
    // resolver (a host-supplied contact list, say) would plug into.
    private let entities: any SlotResolving
    private let session: NLUSession
    private let affirmative: Set<String>
    private let negative: Set<String>
    private var uncertain: [String]
    private var noIdioms: [String]
    private var carrierPatterns: [String]
    /// Anchored alternation of `lexicon.leading_connectors`, or nil when none
    /// were supplied. The third and final step of deriving a topic — see
    /// `deriveTopic`.
    private let leadingConnectorPattern: String?
    /// intent → when it confirms. An intent absent from the map defaults to
    /// `.always`, which is what the pre-pack schema expressed by simply carrying
    /// a `followup`. `PackEngineFactory` supplies a gate for every intent, so
    /// that default is a safety net rather than a path anything takes.
    /// See `ConfirmationGate`.
    private let confirmationGates: [String: ConfirmationGate]
    /// Language-specific connective/function words that signal a mid-thought pause when
    /// a stable transcript ends on one. Injected from the host/pack; defaults to the
    /// English set when not supplied. See `endsWithTrailingFunctionWord`.
    private let trailingFunctionWords: Set<String>

    // MARK: - Init
    //
    // NOTHING HERE DEFAULTS TO ENGLISH ANY MORE.
    //
    // This type used to carry `defaultUncertain`, `defaultNoIdioms` and
    // `defaultCarriers` — three hardcoded English word lists — plus
    // `schema: NLUSchema = .loadFromBundle()` and
    // `entities: EntityExtractor = EntityExtractor()`, both of which read
    // `Bundle.module`. Every one of those was a fallback that a failure could
    // land on, and VIK-001 is what that cost: a lexicon that decoded to an empty
    // struct made the factory substitute all three lists, so a French pack ran
    // English rules with no throw, no log, and a green test suite.
    //
    // Now every input is required and comes from a verified pack. A caller that
    // cannot supply one cannot build an engine, which is the intended
    // difficulty.

    init(
        schema: NLUSchema,
        classifier: any IntentClassifying,
        entities: any SlotResolving,
        uncertain: [String],
        noIdioms: [String],
        carriers: [String],
        /// Language-specific trailing function words. `nil` → the English default set,
        /// preserving prior behaviour for English packs.
        trailingFunctionWords: Set<String>? = nil,
        // Empty by default, which is a no-op — the pre-pack path never had this
        // step, so leaving it out keeps that path byte-identical.
        leadingConnectors: [String] = [],
        confirmationGates: [String: ConfirmationGate] = [:],
        sessionID: String = "default"
    ) {
        self.schema = schema
        self.classifier = classifier
        self.entities = entities
        self.session = NLUSession(sessionID: sessionID)
        self.affirmative = Set(schema.affirmative)
        self.negative = Set(schema.negative)
        self.uncertain = uncertain
        self.noIdioms = noIdioms
        self.carrierPatterns = carriers
        self.confirmationGates = confirmationGates
        self.trailingFunctionWords = trailingFunctionWords ?? []

        // Longest first so "regarding" is not pre-empted by a shorter word that
        // prefixes it, and `(?:\s+|$)` so a connector that is the ENTIRE
        // remainder still goes: "set a reminder for 5pm" reduces to "for", and
        // requiring a trailing space there left the reminder named "for".
        //
        // Written as loops with declared types, NOT `map`/`filter`/`sorted`
        // chained together — that shape is VIK-005, and it made this exact line
        // fail to compile with "unable to type-check this expression in
        // reasonable time". Swift has to solve the element type across every
        // link at once, and the `sorted` closure's ternary is enough to tip it.
        var connectors: [String] = []
        for raw in leadingConnectors {
            let word: String = raw.lowercased()
            if !word.isEmpty { connectors.append(word) }
        }
        connectors.sort { (lhs: String, rhs: String) -> Bool in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs < rhs
        }
        if connectors.isEmpty {
            self.leadingConnectorPattern = nil
        } else {
            var escaped: [String] = []
            for word in connectors {
                escaped.append(NSRegularExpression.escapedPattern(for: word))
            }
            let alternation: String = escaped.joined(separator: "|")
            self.leadingConnectorPattern = "^(?:" + alternation + ")(?:\\s+|$)"
        }
    }

    /// Unconfigured intents confirm, which is how the pre-pack schema behaved.
    private func gate(for intent: String) -> ConfirmationGate {
        confirmationGates[intent] ?? .always
    }

    // MARK: - Public API

    /// Processes one user utterance and returns the next conversational step.
    /// Async because Stage 3 (semantic rescue) runs CoreML inference.
    func handle(_ text: String) async -> NLUResponse {
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
    /// `async` to satisfy `ConversationEngine` (callers on the main actor await
    /// every actor call uniformly); the body itself is synchronous.
    func reset() async {
        session.resetAll()
    }

    /// True when the engine is mid-conversation and the next utterance is an answer.
    var isCollecting: Bool {
        session.pendingIntent != nil || activeConfirmation() != nil
    }

    /// Pre-warms the underlying classifier's CoreML graphs (ANE specialisation).
    /// Delegates to the classifier so callers have a single warm-up entry point.
    func warmUp() async {
        await classifier.warmUp()
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
            // Re-arm the context and ask again. Any slots staged when the
            // confirmation was armed survive, because nothing is reset here.
            session.setContext(fu.context, lifespan: fu.lifespan)
            return .confirm(intent: intent, action: nil, question: fu.prompt, filled: session.pendingSlots)

        case .some(true):
            session.clearContext(fu.context)
            // VIK-021. For an intent that collects slots, "yes" is permission to
            // PROCEED — not the end of the turn. Fulfilling here returns
            // `parameters: [:]`, so "set a reminder to go to the airport" →
            // "shall I?" → "yes" created a reminder with no name and no time,
            // and reported success.
            //
            // `advanceSlots` prompts for the first missing required slot, or
            // fulfils if the opening utterance already supplied them all. Its
            // action and message come from `cfg`, which `PackEngineFactory`
            // builds from the same `workflow.completion` as `fu.yes` — so a
            // no-slot intent and a slot intent finish identically.
            if let cfg = schema.intents[intent],
               !cfg.slots.isEmpty,
               session.pendingIntent == intent {
                return advanceSlots(intent, cfg, breakdown: session.pendingBreakdown)
            }
            session.resetSlotFilling()
            return .fulfill(intent: intent, action: fu.yes.action,
                            parameters: [:], message: fu.yes.fulfillment, confidence: 1.0)

        case .some(false):
            // Declined — drop anything staged, or the next unrelated utterance
            // resumes a flow the user just cancelled.
            session.clearContext(fu.context)
            session.resetSlotFilling()
            return .fulfill(intent: intent, action: fu.no.action,
                            parameters: [:], message: fu.no.fulfillment, confidence: 1.0)
        }
    }

    /// Returns true for yes, false for no, nil for ambiguous/uncertain.
    private func yesNo(_ text: String) -> Bool? {
        var t = text.lowercased().trimmingCharacters(in: .whitespaces)
        for idiom in noIdioms { t = t.replacingOccurrences(of: idiom, with: "") }
        if uncertain.contains(where: { t.contains($0) }) { return nil }
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
            && probe.label != schema.fallbackIntent
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
            if entities.isDateTime(slot.entity) {
                let (iso, filled) = resolveDateTime(text)
                if filled, let iso { session.pendingSlots[slot.name] = iso }
            } else {
                // The user was asked for THIS slot and is answering it, so
                // approximate matching is appropriate — a misheard memory name
                // should still fill.
                var value = entities.extract(slot.entity, from: text, isDirectAnswer: true)
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

        // Track consecutive failures on the awaited slot. Mirrors Python MAX_SLOT_ATTEMPTS = 3:
        // after 3 turns without progress we abandon the flow so the user is never trapped.
        if let awaiting {
            if session.pendingSlots[awaiting] != nil {
                session.slotAttempts = 0
            } else {
                session.slotAttempts += 1
                if session.slotAttempts >= 3 {
                    session.resetSlotFilling()
                    return .fallback(intent: schema.fallbackIntent, confidence: 0)
                }
            }
        }

        return advanceSlots(intent, cfg, breakdown: session.pendingBreakdown)
    }

    private func advanceSlots(_ intent: String, _ cfg: IntentDef,
                               breakdown: ClassificationBreakdown? = nil) -> NLUResponse {
        for slot in cfg.slots where slot.required && session.pendingSlots[slot.name] == nil {
            session.pendingIntent = intent
            session.awaitingSlot = slot.name
            return .prompt(intent: intent, question: slot.prompt, filled: session.pendingSlots)
        }
        let params = session.pendingSlots
        session.resetSlotFilling()
        return .fulfill(intent: intent, action: cfg.action,
                        parameters: params, message: cfg.fulfillment ?? "", confidence: 1.0,
                        breakdown: breakdown)
    }

    // MARK: - Keyword triggers (Stage 0)

    /// Returns the intent name if a declarative keyword trigger fires, nil otherwise.
    /// Matches are performed on lowercased text (mirrors Python classifier._keyword_match).
    private func matchKeywordTrigger(_ text: String) -> String? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        for trigger in schema.keywordTriggers {
            guard let pattern = trigger.regex else { continue }
            let opts: NSString.CompareOptions = [.regularExpression, .caseInsensitive]
            if t.range(of: pattern, options: opts) != nil {
                if let notPattern = trigger.notRegex,
                   t.range(of: notPattern, options: opts) != nil { continue }
                return trigger.intent
            }
        }
        return nil
    }

    // MARK: - New intent (priority 3)

    private func handleNewIntent(_ text: String) async -> NLUResponse {
        session.decrementContexts()

        // Stage 0: declarative keyword triggers bypass TF-IDF for high-precision patterns.
        if let kwIntent = matchKeywordTrigger(text), let cfg = schema.intents[kwIntent] {
            var slots: [String: String] = [:]
            extractAllSlots(cfg, text, into: &slots)
            fillOpenTopics(cfg, text, into: &slots)

            // The confirmation gate applies HERE TOO, and its absence was VIK-021 in a
            // second place. A keyword rule bypasses the CLASSIFIER; it has no business
            // bypassing the POLICY. `pack-en` proves the difference matters: the only
            // intent it gates is `Cmd.SendMessage` (`always`) and that intent ships four
            // keyword rules — so "send a message to…" matched a rule, skipped the gate,
            // and sent without asking, while the pack said always ask.
            //
            // Confidence 1.0, deliberately: a declarative pattern either matched or it
            // did not, so there is no ambiguity to gate on. `always` fires (that is what
            // always means), `when_ambiguous` does not (we are certain), `never` does
            // not. The gate reads as its own name on this path.
            if let fu = cfg.followup, gate(for: kwIntent).fires(confidence: 1.0) {
                session.pendingIntent = cfg.slots.isEmpty ? nil : kwIntent
                session.pendingSlots = slots
                session.awaitingSlot = nil
                session.pendingBreakdown = nil
                session.setContext(fu.context, lifespan: fu.lifespan)
                return .confirm(intent: kwIntent, action: cfg.action, question: fu.prompt, filled: slots)
            }

            session.pendingIntent = kwIntent
            session.pendingSlots = slots
            session.awaitingSlot = nil
            session.pendingBreakdown = nil
            return advanceSlots(kwIntent, cfg)
        }

        let result    = await classifier.classifyAsync(text)
        let intent    = result.label
        let conf      = result.confidence
        let rescued   = result.semanticRescue
        let breakdown = result.breakdown

        // Semantic rescue already passed its own 0.55 gate inside classifyAsync.
        // Do NOT re-apply Stage 2's 0.70 threshold to a semanticRescue result —
        // doing so would drop every rescue (rescue conf 0.55–0.69 → false fallback).
        //
        // The vacuous-prediction path (VIK-011) arrives here too: nothing in the
        // utterance matched the vocabulary, so `PackClassifierAdapter` substitutes
        // `pack.outOfScopeIntent`, which now resolves to the pack's real fallback
        // label instead of "".
        let outOfScope = intent == "OUT_OF_SCOPE" || intent == schema.fallbackIntent
        if !rescued && (outOfScope || conf < schema.confidenceThreshold) {
            return .fallback(intent: schema.fallbackIntent,
                             confidence: conf, breakdown: breakdown)
        }

        guard let cfg = schema.intents[intent] else {
            // Intent recognized but has no schema config — simple single-turn, no slot filling.
            return .fulfill(intent: intent, action: nil, parameters: [:], message: "", confidence: conf, semanticRescue: rescued, breakdown: breakdown)
        }

        // Intent that opens with a yes/no confirmation.
        //
        // Gated on confidence, not merely on the followup existing (VIK-021).
        // The pack marks 14 intents `when_ambiguous` and 43 `never`; confirming
        // whenever a `confirmation` block was present asked on all 14 every
        // time, including when the classifier was certain.
        if let fu = cfg.followup, gate(for: intent).fires(confidence: conf) {
            // Stage the slots this utterance already answers BEFORE asking, so
            // "yes" resumes a half-filled flow instead of starting an empty one.
            // The user said "set a reminder to go to the airport" — the name is
            // in that sentence and must not be asked for again.
            var staged: [String: String] = [:]
            if !cfg.slots.isEmpty {
                extractAllSlots(cfg, text, into: &staged)
                fillOpenTopics(cfg, text, into: &staged)
            }
            session.pendingIntent = cfg.slots.isEmpty ? nil : intent
            session.pendingSlots = staged
            session.awaitingSlot = nil
            session.pendingBreakdown = breakdown
            session.setContext(fu.context, lifespan: fu.lifespan)
            return .confirm(intent: intent, action: cfg.action, question: fu.prompt, filled: staged)
        }

        // Intent that needs slots — extract what we can from this first utterance.
        if !cfg.slots.isEmpty {
            var slots: [String: String] = [:]
            extractAllSlots(cfg, text, into: &slots)
            fillOpenTopics(cfg, text, into: &slots)
            session.pendingIntent = intent
            session.pendingSlots = slots
            session.awaitingSlot = nil
            session.pendingBreakdown = breakdown
            return advanceSlots(intent, cfg, breakdown: breakdown)
        }

        // Simple single-turn intent.
        return .fulfill(intent: intent, action: cfg.action,
                        parameters: [:], message: cfg.fulfillment ?? "", confidence: conf, semanticRescue: rescued, breakdown: breakdown)
    }

    // MARK: - Slot extraction helpers

    private func extractAllSlots(_ cfg: IntentDef, _ text: String,
                                 into slots: inout [String: String], skip: String? = nil) {
        for slot in cfg.slots where slots[slot.name] == nil && slot.name != skip {
            if entities.isDateTime(slot.entity) {
                // Only fill when a time was actually given; a day-only mention
                // parks the day in session.partialDateTime and leaves the slot
                // open so the engine prompts for the time.
                let (iso, filled) = resolveDateTime(text)
                if filled, let iso { slots[slot.name] = iso }
                continue
            }
            // Speculative: this is a sweep of the whole utterance for any slot
            // that happens to be mentioned, not an answer to a prompt. Exact
            // matches only — a fuzzy hit here fills a slot the user never spoke.
            if let value = entities.extract(slot.entity, from: text, isDirectAnswer: false) {
                slots[slot.name] = value
            }
        }
    }

    /// Content-aware endpointing hook (see `ConversationEngine`). Mirrors the slot
    /// resolution rules in `handleSlotFilling`/`resolveDateTime` WITHOUT mutating
    /// session state — this runs speculatively, per stable transcript, while the
    /// user may still be mid-answer.
    func assessSlotAnswer(_ text: String) -> SlotAnswerAssessment {
        guard let intent = session.pendingIntent,
              let cfg = schema.intents[intent],
              let awaiting = session.awaitingSlot,
              let slot = cfg.slots.first(where: { $0.name == awaiting })
        else {
            // No pending slot — this is an INITIAL command, not a slot answer. We
            // can't verify command completeness against a schema, but we CAN catch the
            // obvious mid-thought case: a command ending on a connective/function word
            // ("set the volume to…", "remind me to…") is almost certainly unfinished,
            // so extend the window instead of committing at the fast timeout. Anything
            // else endpoints normally. This gives first commands the same short-pause
            // tolerance that slot answers already had.
            return endsWithTrailingFunctionWord(text) ? .incomplete : .complete
        }

        if entities.isDateTime(slot.entity) {
            // Complete only with an explicit time: "tomorrow 6 AM", "at 5", "in 20
            // minutes". A bare day ("tomorrow") parses but would be parked and
            // re-prompted — give the user time to finish the thought instead.
            guard let match = entities.dateTime(in: text, now: Date()) else { return .incomplete }
            return match.timeExplicit ? .complete : .incomplete
        }
        if entities.isOpen(slot.entity) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return .incomplete }
            // A free-text answer whose last word is a connective/function word is
            // almost certainly mid-phrase ("going out for a…"). English-only
            // heuristic; other languages skip it and report .freeform.
            if endsWithTrailingFunctionWord(trimmed) { return .incomplete }
            // Free text can never be VERIFIED complete ("drink" vs "drink water") —
            // report .freeform so the endpoint uses the medium window, tolerating a
            // mid-topic thinking pause without paying the full extended wait.
            return .freeform
        }
        return entities.extract(slot.entity, from: text, isDirectAnswer: true) != nil
            ? .complete : .incomplete
    }

    /// Words that essentially never end a complete English phrase. A stable
    /// transcript ending in one of these is mid-thought — extend the endpoint
    /// window rather than committing the turn.
    ///
    /// True when the last word of `text` is a connective/function word in the active
    /// language's set — a strong signal the speaker is mid-thought ("set the volume
    /// to…", "remind me to…"). A `false` means "no signal", not "verified complete".
    private func endsWithTrailingFunctionWord(_ text: String) -> Bool {
        let lastWord = text.trimmingCharacters(in: .whitespaces).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .last ?? ""
        return trailingFunctionWords.contains(lastWord)
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
        guard var match = entities.dateTime(in: text, now: Date()) else {
            return (nil, false)
        }
        // Bare time with no day of its own — anchor it to the parked day so
        // "tomorrow" is preserved (resolve against that day's midnight).
        if !match.explicitDay,
           let parked = session.partialDateTime.flatMap({ Self.parseLocalISO($0) }),
           let anchored = entities.dateTime(in: text, now: parked) {
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

    // Local wall-clock ISO (no zone), matching the format of `SlotDateTime.iso`.
    private static func localISOFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }
    private static func parseLocalISO(_ s: String) -> Date? { localISOFormatter().date(from: s) }
    private static func formatLocalISO(_ d: Date) -> String { localISOFormatter().string(from: d) }

    /// Three steps, in this order, mirroring `engine.py::_derive_topic`:
    /// carriers → date/time → leading connector.
    ///
    /// For required "open" slots not yet filled, derive a free-text topic from the utterance.
    /// Fills an OPEN required slot with the utterance's derived topic — and overrides
    /// whatever the speculative gazetteer sweep put there first.
    ///
    /// The override is the fix. `extractAllSlots` runs before this and matches the whole
    /// utterance against every entity table, including open ones; "set a reminder to
    /// drink water" hit `remind`'s hint list and stored its CANONICAL form, so the
    /// reminder was named "Drink Water" while the user said "drink water", and this
    /// function then skipped the slot because it was no longer nil.
    ///
    /// An open entity's value list is a hint, not a vocabulary (VIK-017). When the slot
    /// is the thing the user is naming, their words are the answer and the gazetteer's
    /// title-case is a rewrite of them. The Python reference derives the topic here; the
    /// parity fixtures are what caught the divergence.
    ///
    /// Only the opening-utterance paths call this, so the mid-flow opportunistic sweep
    /// is untouched.
    private func fillOpenTopics(_ cfg: IntentDef, _ text: String, into slots: inout [String: String]) {
        for slot in cfg.slots {
            guard slot.required, entities.isOpen(slot.entity) else { continue }
            if let topic = deriveTopic(text), !topic.isEmpty {
                slots[slot.name] = topic
            }
        }
    }

    private func deriveTopic(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces)
        // Apply ALL carriers in order (mirrors Python: each '^' pattern strips from the
        // updated start of string, enabling two-step stripping like "veuillez" then "régler une alarme").
        for pattern in carrierPatterns {
            if let range = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                t.removeSubrange(range)
            }
        }
        var stripped = entities.strippingDateTime(t)
        // Step 3, which was missing entirely: the connective that introduced the
        // now-removed time is still at the front. "Remind me at 9pm for dinner"
        // derived "for dinner"; "set a reminder for 5pm" derived "for" and
        // stored that as the reminder's name.
        if let pattern = leadingConnectorPattern,
           let range = stripped.range(of: pattern,
                                      options: [.regularExpression, .caseInsensitive]) {
            stripped.removeSubrange(range)
        }
        stripped = stripped.trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
        return stripped.isEmpty ? nil : stripped
    }

    // MARK: - Stage 3 lifecycle

    /// Loads MiniLM + SemanticHead and triggers ANE specialization.
    /// After this call, low-confidence Stage 2 results are rescued by Stage 3.
    func loadStage3() async {
        await classifier.loadStage3()
    }

    /// Releases Stage 3 refs. Stage 3 is skipped on future classifications.
    func releaseStage3() async {
        await classifier.releaseStage3()
    }

    deinit {
        lifecycleLog.debug("[Deinit] NLUEngine")
    }

    // MARK: - Misc

    private func wholeWord(_ word: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return text.range(of: "\\b\(escaped)\\b", options: .regularExpression) != nil
    }
}
