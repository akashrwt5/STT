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
        /// `policies.thresholds.interrupt`. Deliberately has no default: see the
        /// property's note, and the VIK-001 paragraph below.
        interruptThreshold: Double,
        /// `policies.limits.max_slot_attempts`. No default, same reasoning.
        maxSlotAttempts: Int,
        /// `policies.thresholds.oov_reject` and `oov_bypass`. A PAIR — the guard
        /// runs only when both are present, because half of it is worse than
        /// neither. Nil disables it, which is what a pack predating them means.
        oovReject: Double?,
        oovBypass: Double?,
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
        self.interruptThreshold = interruptThreshold
        self.maxSlotAttempts = maxSlotAttempts
        self.oovReject = oovReject
        self.oovBypass = oovBypass
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
    ///
    /// CONTENT-OWNED — `policies.thresholds.interrupt`. There is no default here,
    /// for the reason the initializer gives: a constant in this file is a value no
    /// language pack can override.
    ///
    /// It was `private static let interruptThreshold: Double = 0.75`, documented as
    /// "Mirrors Python NLUEngine.INTERRUPT_THRESHOLD = 0.75". That mirrored the
    /// wrong number. 0.75 is Python's DEFAULT_INTERRUPT_THRESHOLD, the fallback for
    /// a schema that omits the key, and `engine.py` says so in as many words:
    /// "The live value is CONTENT-OWNED ... read it from `self.interrupt_threshold`,
    /// not from here." pack-en carries 0.68, so on every probe scoring in
    /// [0.68, 0.75) Python abandoned the flow and Swift did not — same pack, same
    /// utterance, two answers. The VIK-038 gate bounds the blast radius to closed
    /// enum slots (`memory`), because open and date-time slots never probe at all.
    private let interruptThreshold: Double

    /// Consecutive failed turns on one awaited slot before the flow is abandoned.
    ///
    /// CONTENT-OWNED — `policies.limits.max_slot_attempts`. It was a bare `3`
    /// written into the comparison below, next to a pack that declared the same
    /// budget and a reference engine that hardcoded its own: three independent
    /// 3s that agreed only by coincidence, and a pack field no one could change.
    /// Python now reads it from the content too (`self.max_slot_attempts`).
    private let maxSlotAttempts: Int

    /// Out-of-vocabulary guard, `policies.thresholds.oov_reject` / `oov_bypass`.
    /// Read as a pair or not at all — see `handleNewIntent`.
    private let oovReject: Double?
    private let oovBypass: Double?

    private func handleSlotFilling(_ text: String) async -> NLUResponse {
        guard let intent = session.pendingIntent, let cfg = schema.intents[intent] else {
            session.resetSlotFilling()
            return await handleNewIntent(text)
        }

        // VIK-038. Topic-switch probe — but ONLY when the awaited slot can produce
        // evidence that this utterance is not an answer to it.
        //
        // The classifier is trained on COMMANDS. A slot answer is out-of-distribution
        // input for it, and a confidence score on OOD input is not a quantity that can
        // be thresholded. Measured on this pack's own weights, answering the reminder's
        // "what shall I remind you about?" with
        //
        //     "Need to go to walk"     -> Cmd.ActivityWalk      0.994
        //     "clean my hearing aids"  -> Help_CleanCare        1.000
        //     "start my workout"       -> Cmd.ActivityExercise  0.995
        //
        // cancelled the reminder the user was in the middle of setting. Raising the
        // interrupt threshold does not help: "start my workout" (a legitimate reminder)
        // outscores "start transcribing" (a real command, 0.962).
        //
        // What DOES carry evidence is the slot itself, so the gate is the awaited
        // entity's KIND — never the intent's name, which this package does not
        // interpret (see ResolvedPack.swift's second design rule):
        //
        //   closed gazetteer  the value is in the list or it is not. A miss is a
        //                     fact, and the only honest reason to ask the classifier
        //                     where the user went instead. PROBE.
        //   open free-text    every utterance is a legal value. There is nothing to
        //                     be right about. DO NOT PROBE.
        //   date-time         the parser decides, not the classifier. DO NOT PROBE.
        //
        // For `pack-en` that means the reminder flow (`remind` open + `sys.date_time`)
        // never interrupts, and the memory flow (`memory`, 38 values) still does —
        // "increase volume" is not a memory, so it still switches topic correctly.
        let awaitedEntity = session.awaitingSlot
            .flatMap { name in cfg.slots.first { $0.name == name } }?
            .entity
        let slotCanRefuseTheAnswer: Bool = {
            // No slot awaited: leave the pre-existing behaviour alone.
            guard let awaitedEntity else { return true }
            return !entities.isOpen(awaitedEntity) && !entities.isDateTime(awaitedEntity)
        }()

        if slotCanRefuseTheAnswer {
            let probe = await classifier.classifyAsync(text)
            let isNewIntent = probe.label != intent
                && probe.label != schema.fallbackIntent
                && probe.label != "OUT_OF_SCOPE"
                && probe.confidence >= interruptThreshold
                && schema.intents[probe.label] != nil
            if isNewIntent {
                let abandoned = intent
                session.resetSlotFilling()
                let newResult = await handleNewIntent(text)
                return .interrupted(cancelledIntent: abandoned, result: newResult)
            }
        }

        // The utterance answers the slot we last prompted for.
        let awaiting = session.awaitingSlot
        if let awaiting,
           let slot = cfg.slots.first(where: { $0.name == awaiting }) {
            if entities.isDateTime(slot.entity) {
                let (iso, filled) = resolveDateTime(text)
                if filled, let iso { session.pendingSlots[slot.name] = iso }
            } else if entities.isOpen(slot.entity) {
                // VIK-039, the half VIK-037 left open — its fix reached only the three
                // opening-utterance paths that call `fillOpenTopics`, and said so.
                //
                // OPEN free-text slot (e.g. @remind): the user's own words are the
                // value, so derive the topic exactly the way the OPENING utterance
                // already does through `fillOpenTopics` — strip the carrier, strip
                // the date/time, strip the connective it left behind.
                //
                // This is what makes "remind me to call mom at 9am" produce the same
                // name whether it opens the conversation or answers the prompt. It
                // did not before: the opening ran `deriveTopic` and the answer took
                // the raw text, so the same sentence became "call mom" in one place
                // and "remind me to call mom at 9am" in the other.
                //
                // The time is NOT lost by stripping it here. `extractAllSlots` below
                // runs over this same utterance and resolves the date-time slot from
                // it, so "at 9am" leaves the name and arrives in `date_time`.
                //
                // The gazetteer is deliberately NOT consulted for an open entity. Its
                // value list is a HINT, not a value set — matching it returns the
                // CANONICAL and discards the rest of the sentence, so "I need to pick
                // up prescription" became "Pick Up Prescription" and "drink water"
                // became "Drink Water" while "buy milk" stayed verbatim. Same slot,
                // three different shapes. Skipping it also removes the fuzzy hazard:
                // `remind` is `fuzzy: true`, and its only fuzzy-eligible synonym is
                // "activity", which "acidity" and "captivity" are both within the
                // edit-distance limit of.
                session.pendingSlots[slot.name] =
                    deriveTopic(text) ?? text.trimmingCharacters(in: .whitespaces)
            } else {
                // CLOSED entity. The user was asked for THIS slot and is answering it,
                // so approximate matching is appropriate — a misheard memory name
                // should still fill. Unchanged.
                if let value = entities.extract(slot.entity, from: text, isDirectAnswer: true) {
                    session.pendingSlots[slot.name] = value
                }
            }
        }

        // Opportunistically fill OTHER slots mentioned in the same answer; skip the
        // slot we just handled so a parked date-time isn't re-resolved (and the day
        // double-advanced) by anchoring it to itself.
        extractAllSlots(cfg, text, into: &session.pendingSlots, skip: awaiting)

        // Track consecutive failures on the awaited slot. The budget is the PACK's
        // (`policies.limits.max_slot_attempts`); Python reads the same content value.
        // After it is spent the flow is abandoned so the user is never trapped.
        if let awaiting {
            if session.pendingSlots[awaiting] != nil {
                session.slotAttempts = 0
            } else {
                session.slotAttempts += 1
                if session.slotAttempts >= maxSlotAttempts {
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
        // VIK-054. OUT-OF-VOCABULARY GUARD. A confident reading of the words the
        // featurizer CAN see says nothing about the words it cannot.
        //
        // The TF-IDF vocabulary is a fixed set of columns. A token outside it is
        // not weighed and dismissed — there is nowhere to put it, so the sentence
        // reaches the model without it. "help me find a paper" arrives as "help
        // me find", on which `Help_FindMyHearingAids` at 0.771 is a correct
        // answer to a question the user did not ask. The confidence is honest
        // about the input the model was GIVEN, which is why no threshold can fix
        // this and a separate signal is needed.
        //
        // Both halves or neither. Entity values are out-of-vocabulary BY NATURE —
        // a contact name, a brand, a free-text reminder topic can never all be in
        // a finite vocabulary — so the ratio alone refuses real commands. Measured
        // on this pack's own weights:
        //
        //     'send a message to john'   oov 0.25, conf 1.000   <- a real command
        //     'stream from netflix'      oov 0.33, conf 0.996   <- a real command
        //     'help me find a paper'     oov 0.25, conf 0.771   <- out of scope
        //
        // The first and third have the SAME ratio; only the confidence separates
        // them, which is what `oovBypass` is for. Adding that condition kept the
        // out-of-scope reduction (10 -> 5) and returned 7 correct commands the
        // bare ratio was refusing.
        //
        // Placed immediately before the fire test, as in the reference engine, so
        // it can only ever WITHHOLD an action and never cause one. One knowing
        // difference from Python: there, the guard runs before semantic rescue is
        // attempted, so a blocked turn never reaches it. Here rescue has already
        // happened inside `classifyAsync`, so a rescued turn is guarded on the
        // rescue's confidence. Moot while the pack disables the semantic stage;
        // recorded because it is the kind of ordering that becomes a divergence
        // the day it is enabled.
        let outOfScope = intent == "OUT_OF_SCOPE" || intent == schema.fallbackIntent
        if let reject = oovReject, let bypass = oovBypass, !outOfScope, conf < bypass {
            let ratio = await classifier.oovRatio(text)
            if ratio >= reject {
                return .fallback(intent: schema.fallbackIntent,
                                 confidence: conf, breakdown: breakdown)
            }
        }

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
        // ORDER MATTERS, and the date/time goes FIRST.
        //
        // Every carrier is `^`-anchored, so a carrier is only reachable when it is at
        // the front of the string — and a leading time expression pushes it out of
        // reach:
        //
        //   "tomorrow morning remind me to water the plants"
        //     carriers first  -> "^remind me" misses -> "remind me to water the plants"
        //     date/time first -> "remind me to water the plants" -> "water the plants"
        //
        // Safe in the other direction because `strippingDateTime` only ever REMOVES
        // text, never prepends. Running it first can only move an `^`-anchored carrier
        // closer to the front, never further from it — the change is strictly additive,
        // and the common shape ("remind me to drink water at 5", time in the middle or
        // at the end) is untouched.
        //
        // PARITY: mirrors `engine.py::_derive_topic`, which was reordered in the same
        // change. Verified equal across a 41-case battery on both runtimes.
        var t = entities.strippingDateTime(text.trimmingCharacters(in: .whitespaces))
        // Apply ALL carriers in order (mirrors Python: each '^' pattern strips from the
        // updated start of string, enabling two-step stripping like "veuillez" then "régler une alarme").
        for pattern in carrierPatterns {
            if let range = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                t.removeSubrange(range)
            }
        }
        var stripped = t
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
