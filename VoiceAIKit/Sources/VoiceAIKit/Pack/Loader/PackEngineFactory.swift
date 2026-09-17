// PackEngineFactory.swift
// VoiceAIKit
//
// Builds a live `ConversationEngine` from a `ResolvedPack`. This is the seam
// where the pack becomes the runtime's source of truth.
//
// It replaces `NLUEngineFactoryProvider`, which resolved a `LanguagePack`
// manifest out of `Bundle.module`, merged a per-language overlay onto the
// English schema via `LocalizationLoader`, and — when any of that failed —
// silently substituted `NLUEngine.defaultUncertain` / `defaultNoIdioms` /
// `defaultCarriers`, all hardcoded English (VIK-001).
//
// STAGED ON PURPOSE. This file adapts the pack onto the EXISTING `NLUEngine`
// rather than rewriting its 469 lines of dialog logic — confirmation handling,
// slot filling, interruption detection — which is real, tested behaviour and
// not something to reimplement while also changing where data comes from. The
// engine keeps its shape; only its inputs change, and they now come from one
// verified pack instead of eleven bundle lookups.
//
// What that leaves for the next step: `NLUSchema` still EXISTS as a type, but
// nothing reads it from `Bundle.module` any more — it is populated from the pack
// here. Deleting it, along with `EntityExtractor`, `NLULexicon`,
// `LocalizationLoader`, `LanguagePackRegistry`, `ClassifierBundle` and the
// `Resources/` tree, is mechanical once this path is proven live.

import Foundation
import os.log

enum PackEngineFactory {

    private static let log = Logger(subsystem: "com.voiceaikit", category: "PackEngineFactory")

    /// Build an engine bound to `pack`.
    ///
    /// No language argument: a `ResolvedPack` is already bound to exactly one
    /// language. That is the point — there is no "fall back to English" branch
    /// to take, because there is no English to fall back to.
    /// - Parameters:
    ///   - stopwords: OPTIONAL override for fuzzy-matching stopwords. When nil (the
    ///     normal case) the pack's own `lexicon.fuzzyStopwords` is used, so each
    ///     language ships its own list — no hardcoded English. Pass a value only to
    ///     override the pack.
    ///   - trailingFunctionWords: OPTIONAL override for the mid-thought endpointing
    ///     word set. When nil, the pack's own `lexicon.trailingFunctionWords` is used.
    ///
    /// There is no longer a `gaps` parameter. `PackContentGaps` existed because
    /// the v3 projection dropped the `open` entity flag and the compiler's
    /// portable-regex check silently discarded the "set a reminder" carrier
    /// (VIK-017, VIK-022), so a host had to supply both. Both are fixed at the
    /// source and carried by `pack-en-v1.0.30` onward, so the workaround is gone
    /// rather than defaulted — a parameter nobody sets is a parameter someone
    /// eventually sets wrongly.
    ///
    /// The entity extractor is no longer a parameter. It was injected while
    /// `NLUEngine` depended on the concrete `EntityExtractor`, which reads a file
    /// and cannot be built from a pack; the engine now depends on
    /// `SlotResolving`, so the pack-driven implementation is built here where the
    /// pack is.
    static func makeEngine(pack: ResolvedPack,
                                  stopwords: Set<String>? = nil,
                                  trailingFunctionWords: Set<String>? = nil) throws -> any ConversationEngine {
        let classifier = try PackClassifierAdapter(pack: pack)
        let lexicon = pack.lexicon

        // Fuzzy stopwords and trailing function words are DATA — they come from the
        // pack's lexicon (`lexicons/<lang>.json`), which carries them per language, so
        // a non-English pack ships its own without a code change. The host `stopwords` /
        // `trailingFunctionWords` parameters are an OPTIONAL OVERRIDE for a host that
        // wants to tune them; when nil (the normal case) the pack's own lists win. This
        // is what makes them data-driven rather than hardcoded English (see VIK-007).
        let effectiveStopwords = stopwords ?? lexicon.fuzzyStopwords.map { Set($0) }
        let effectiveTrailingWords = trailingFunctionWords ?? lexicon.trailingFunctionWords.map { Set($0) }

        let entities = PackSlotResolver(pack: pack, stopwords: effectiveStopwords)

        // Word lists come from the pack's lexicon. Empty is a legitimate answer
        // for a language that does not use a mechanism — it is NOT a signal to
        // substitute English, which is exactly what the predecessor did.
        let engine = NLUEngine(
            schema: try schema(from: pack),
            classifier: classifier,
            entities: entities,
            // EMPTY, not `lexicon.negationCues` (VIK-023).
            //
            // `uncertain` means "the user answered neither yes nor no" — the
            // English list was ["not sure", "maybe", "dunno", …]. `negation_cues`
            // is a different table: words that NEGATE. Seven of the twelve words
            // in the pack's own `negative` list contain one as a substring
            // ("cancel", "stop", "don't", "never mind"…), and the check is
            // `contains`, not whole-word. So wiring the two together made
            // `yesNo` return nil for exactly the words a user says to decline —
            // the engine re-asked the same question instead of cancelling, and
            // there is no way out of that loop except saying "no".
            //
            // Empty is the honest value: the pack carries no uncertainty table.
            // The cost is that "I don't know" now reads as a decline rather than
            // a re-prompt, which fails safe. The cost of the alternative was a
            // user who cannot cancel.
            uncertain: [],
            noIdioms: [],
            carriers: lexicon.carriers,
            // The pack's own bar, not a constant in the engine. Python reads the
            // same number out of `interrupt_threshold`; that is the parity.
            interruptThreshold: pack.policies.thresholds.interrupt,
            maxSlotAttempts: pack.policies.limits.maxSlotAttempts,
            // The pair the compiler emits from one statement; passed the same way.
            oovReject: pack.policies.thresholds.oovReject,
            oovBypass: pack.policies.thresholds.oovBypass,
            // VIK-055. Decoded since the v3 surface landed and read by nothing
            // until now, which is exactly why the engine applied a flat bar where
            // the reference drops it for a corroborated turn.
            agreementThreshold: pack.policies.thresholds.agreement,
            trailingFunctionWords: effectiveTrailingWords,
            leadingConnectors: lexicon.leadingConnectors,
            confirmationGates: confirmationGates(from: pack),
            // ND-14, from `runtime/guards.json`. Every pack this loader has ever
            // read has shipped it; `PackGuards` was decoded and validated for
            // dangling intents and then never applied, so a device STARTED
            // transcription when asked how to use it while the reference engine
            // showed help.
            // A bare entity value is not a request: "outdoors" names a memory,
            // and a device that switches programs on a stray word heard by an
            // always-on mic is the worst failure this pack can produce. Empty
            // for a pack predating the guard, which leaves behaviour unchanged.
            bareValueGuards: pack.guards.bareValue,
            helpMarkerPattern: pack.guards.helpMarker?.markers,
            helpPairs: pack.guards.helpMarker?.pairs ?? [:])

        log.info("""
            Engine ready — \(pack.manifest.bundleID, privacy: .public) \
            [\(pack.language, privacy: .public)], \(pack.intents.count) intents, \
            \(pack.classifier.variant.rawValue, privacy: .public) head, \
            keyword stage \(pack.stageEnabled(.keyword) ? "on" : "off", privacy: .public), \
            agreement bar \(pack.policies.thresholds.agreement.map { String($0) } ?? "off", privacy: .public)
            """)
        return engine
    }

    // MARK: - Pack → confirmation policy

    /// Project `policies.confirmation` + `policies.thresholds` onto the gate the
    /// engine reads (VIK-021).
    ///
    /// These are the tables that decide whether an intent confirms. The
    /// `confirmation` block inside a workflow is NOT one of them — it only
    /// supplies the question's response key, and reading it as the decision is
    /// what made all 14 gated intents confirm unconditionally.
    static func confirmationGates(from pack: ResolvedPack) -> [String: ConfirmationGate] {
        let band = pack.uncertainConfirmBand
        if band == nil {
            // ADD rule: a runtime must not invent the band. Without it
            // `when_ambiguous` is undecidable, and "confirm always" is the more
            // damaging of the two guesses — it is the behaviour this fixes.
            log.error("""
                Pack \(pack.manifest.bundleID, privacy: .public) omits \
                uncertain_confirm_below/_floor, so `when_ambiguous` cannot be evaluated. \
                Treating those intents as `never` — they will act without confirming.
                """)
        }

        var gates: [String: ConfirmationGate] = [:]
        for id in pack.intents.keys {
            switch pack.confirmationPolicy(for: id) {
            case .always:
                gates[id] = .always
            case .never:
                gates[id] = .never
            case .whenAmbiguous:
                if let band {
                    gates[id] = .whenAmbiguous(floor: band.floor, ceiling: band.ceiling)
                } else {
                    gates[id] = .never
                }
            }
        }
        return gates
    }

    // MARK: - Pack → NLUSchema

    /// Project the pack's dialog tables into the shape `NLUEngine` reads.
    ///
    /// Response KEYS are resolved to text here, which is the whole reason the
    /// v3 surface separates them: the engine wants strings, the pack stores
    /// structure plus a per-language catalog, and the join happens once, after
    /// the language is known.
    static func schema(from pack: ResolvedPack) throws -> NLUSchema {
        var intents: [String: IntentDef] = [:]

        for (id, workflow) in pack.intents {
            let slots: [SlotDef] = workflow.slots.map { slot in
                SlotDef(name: slot.name,
                        entity: slot.entity,
                        required: slot.required,
                        prompt: pack.responses[slot.prompt] ?? "")
            }
            var followup: FollowupDef?
            if let confirmation = workflow.confirmation,
               let prompt = pack.responses[confirmation.prompt] {
                // READ, not inferred. The branches used to be built from
                // `completion`: `completion.action` for yes, and a literal ""
                // plus the shared `sys.confirm.cancelled` text for no. The yes
                // guess is the subtle one — it is right only while ACCEPTING a
                // confirmation means the same thing as NEVER BEING ASKED. The
                // moment content authored `message.send` for yes and
                // `message.cancel` for no, Python fired those and iOS fired
                // `message.compose` and nothing: same pack, same words, two
                // answers, and nothing anywhere went red.
                //
                // But a `confirmation` block does NOT mean the intent is gated.
                // The compiler writes one for every intent that authors a
                // `confirm_prompt`, and pack-en has 13 of those whose policy is
                // `never` — a prompt for a question that is never asked.
                // `runtime/policies.json` decides, and the engine agrees: it
                // arms a confirmation only `if let fu = cfg.followup`, so an
                // intent with no branches simply never asks. Demanding branches
                // from those refused a pack that was correct, which is how this
                // first shipped.
                //
                // So the rule is the narrow one: a GATED intent must state both
                // answers. Absent there, throw — the pack invariant at the top
                // of `ResolvedPack` — because the alternative is the silent
                // divergence above, on the intents most likely to act.
                if let yes = confirmation.yes, let no = confirmation.no {
                    guard let yesText = pack.responses[yes.response] else {
                        throw VoiceIntentError.danglingResponseKey(intent: id, key: yes.response)
                    }
                    guard let noText = pack.responses[no.response] else {
                        throw VoiceIntentError.danglingResponseKey(intent: id, key: no.response)
                    }
                    followup = FollowupDef(
                        context: id,
                        lifespan: 1,
                        prompt: prompt,
                        // `label` is the host's single name for this outcome,
                        // absent for a pack whose host reads plain intent ids —
                        // in which case the engine reports the intent unchanged.
                        yes: FollowupBranch(action: yes.action, fulfillment: yesText, label: yes.label),
                        no: FollowupBranch(action: no.action, fulfillment: noText, label: no.label))
                } else if pack.confirmationPolicy(for: id) != .never {
                    throw VoiceIntentError.confirmationBranchesMissing(intent: id)
                }
            }
            intents[id] = IntentDef(
                slots: slots,
                action: workflow.completion?.action,
                fulfillment: workflow.completion.flatMap { pack.responses[$0.response] },
                followup: followup)
        }

        return NLUSchema(
            version: pack.policies.policySchema,
            confidenceThreshold: pack.policies.thresholds.confidence,
            fallbackIntent: pack.outOfScopeIntent ?? NLUSchema.defaultFallbackIntent,
            intents: intents,
            affirmative: pack.lexicon.affirmative,
            negative: pack.lexicon.negative,
            cancelCues: pack.lexicon.cancelCues,
            // DEPRECATED (VIK-055). The keyword stage now lives in
            // `PackClassifierAdapter`, which reads `PackKeywords.Rule` directly.
            // Nothing consumes this any more, and it must not be revived: the
            // projection is LOSSY — it keeps only `guards.first`, so a rule with
            // two guards would fire where the pack says it must stay silent
            // (VIK-058). Kept for one release rather than deleted, because
            // removing it changes `NLUSchema`'s memberwise init and forces edits
            // across four test files for no behavioural reason.
            keywordTriggers: pack.keywordRulesByTier.map {
                KeywordTrigger(intent: $0.intent,
                               regex: $0.pattern,
                               notRegex: $0.guards.first)
            })
    }

}

// MARK: - Classifier adapter

/// Presents `PackIntentClassifier` through the `IntentClassifying` contract the
/// engine and view model depend on.
///
/// A thin actor rather than making `PackIntentClassifier` conform directly: the
/// protocol carries legacy surface (Stage-3 lifecycle) that the pack-driven
/// classifier has no business knowing about. Keeping the adaptation here means
/// the protocol can shrink later without touching the classifier — `genaiURL`
/// was the first thing to leave that way.
actor PackClassifierAdapter: IntentClassifying {

    private static let log = Logger(subsystem: "com.voiceaikit", category: "PackClassifierAdapter")

    /// Confidence reported when a rule fires but the model's top prediction is a
    /// DIFFERENT intent. The rule still wins the LABEL — it is a deliberate,
    /// hand-authored product decision — but the disagreement is real evidence of
    /// ambiguity and the number has to say so.
    ///
    /// Carried verbatim from `classifier.py`'s `CONTESTED_CONFIDENCE` and
    /// Android's `OfflineNluServiceImpl.contestedConfidence`. Do NOT re-derive
    /// it here: the reference marks it PROVISIONAL pending an out-of-fold sweep,
    /// and a second number invented on this platform would break parity by
    /// definition. It sits BELOW `policies.thresholds.confidence` on purpose, so
    /// a contested rule can never fire on its own.
    ///
    /// VIK-070: this is the one number in the fire path that the PACK does not
    /// own, on any of the three runtimes. It works only while `confidence` stays
    /// above it — a language pack shipping a better-calibrated head and a 0.55
    /// fire threshold would make every contested turn fire, on that language
    /// only, with no code change and nothing to fail. That is VIK-050's failure
    /// mode. See `docs/things-to-pull-from-android.md` §3.
    static let contestedConfidence = 0.60

    /// Reported when a rule fires and the model names a DIFFERENT IN-SCOPE
    /// intent. The rule wins outright, exactly as it did before VIK-055.
    ///
    /// NOT A PROBABILITY, and `Arbitration.ruleOnly` is what says so. A
    /// deterministic pattern either matched or it did not; there is no
    /// distribution behind this number. It is 1.0 because the turn must clear
    /// the fire bar on the rule's authority alone — which is also what makes the
    /// OOV guard stand down (it is gated on `conf < oov_bypass`) and what the
    /// confirmation gate reads, both matching the behaviour this preserves.
    ///
    /// Measured on `holdout_honest.csv` (n=1470): sending these turns to the
    /// contested path instead cost 9 correct turns out of 20 and removed no
    /// wrong actions. See `docs/VIK-055-keyword-arbitration-plan.md`.
    static let ruleOnlyConfidence = 1.0

    private let classifier: PackIntentClassifier
    private let outOfScopeIntent: String
    /// The pack decides whether semantic rescue runs — not the host, and not
    /// this adapter. en packs ship it disabled and their report card was
    /// measured that way.
    private let semanticEnabled: Bool
    /// The pack's keyword rules, compiled once. Empty when the pack disables the
    /// keyword stage — which is this feature's OTA kill switch: a pack shipping
    /// `stages.keyword.enabled = false` routes on the model alone, with no app
    /// update and a known accuracy cost rather than an unknown one.
    private let keywordRules: [CompiledRule]

    /// One keyword rule with its patterns compiled ahead of the turn, so matching
    /// never compiles. The old Stage 0 called `range(of:options:.regularExpression)`
    /// per rule per utterance, which recompiles every pattern on every turn.
    private struct CompiledRule {
        let intent: String
        let pattern: NSRegularExpression
        /// ALL of the rule's guards, not `guards.first` (VIK-058). Any one of
        /// them matching vetoes the rule.
        let vetoes: [NSRegularExpression]

        func matches(_ text: String) -> Bool {
            let range = NSRange(text.startIndex..., in: text)
            guard pattern.firstMatch(in: text, options: [], range: range) != nil else { return false }
            return !vetoes.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
        }
    }

    init(pack: ResolvedPack) throws {
        // The head was fitted on normalised text (contractions expanded,
        // apostrophes dropped, plurals folded). Handing it anything else loses
        // features silently — see `PackTextNormalizer` for the measurement.
        self.classifier = try PackIntentClassifier(
            artifacts: pack.classifier,
            normalizer: PackTextNormalizer(lexicon: pack.lexicon))
        self.outOfScopeIntent = pack.outOfScopeIntent ?? ""
        self.semanticEnabled = pack.stageEnabled(.semantic)

        // Order is the pack's `keywordRulesByTier` — tier 1 (exact anchors)
        // before tier 2 — and it is preserved here deliberately. Android matches
        // in FILE order instead (VIK-057); changing that belongs in its own PR
        // with a sweep behind it, not folded into this one.
        var compiled: [CompiledRule] = []
        if pack.stageEnabled(.keyword) {
            for rule in pack.keywordRulesByTier {
                // A pattern this platform cannot compile costs that ONE rule, not
                // the load — the pack is otherwise fine, and NSRegularExpression's
                // dialect is not identical to Python's `re`. Same discipline as
                // `NLUEngine`'s help-marker compilation.
                guard let pattern = try? NSRegularExpression(pattern: rule.pattern,
                                                             options: [.caseInsensitive]) else {
                    Self.log.error("""
                        Keyword rule for \(rule.intent, privacy: .public) does not compile here \
                        — dropping it. The rule will never fire on this platform.
                        """)
                    continue
                }
                var vetoes: [NSRegularExpression] = []
                var guardsUsable = true
                for veto in rule.guards {
                    guard let expr = try? NSRegularExpression(pattern: veto,
                                                              options: [.caseInsensitive]) else {
                        guardsUsable = false
                        break
                    }
                    vetoes.append(expr)
                }
                // A rule whose GUARD will not compile is dropped whole, never kept
                // unguarded: an unguarded rule fires where the pack says it must
                // stay silent, which is the more damaging of the two failures.
                guard guardsUsable else {
                    Self.log.error("""
                        A guard on the keyword rule for \(rule.intent, privacy: .public) does not \
                        compile here — dropping the rule rather than running it unguarded.
                        """)
                    continue
                }
                compiled.append(CompiledRule(intent: rule.intent, pattern: pattern, vetoes: vetoes))
            }
        }
        self.keywordRules = compiled
    }

    /// The intent of the first rule that fires, or nil when none do.
    ///
    /// Matches RAW text. `classifier.py` is explicit that normalisation is
    /// "applied to the MODEL path only — the keyword stage matches raw text".
    ///
    /// THAT DISTINCTION IS NOW LIVE. It used to read "iOS applies no
    /// normalisation at all today (VIK-056), so both paths currently see the
    /// same string" — true until `PackTextNormalizer` landed. `classifyAsync`
    /// calls this function and `classifier.classify` on the same argument, and
    /// they no longer see the same string:
    ///
    ///     input                      keyword stage        model path
    ///     "don't mute it"            don't mute it        do not mute it
    ///     "change my memories"       change my memories   change my memory
    ///
    /// Keeping the keyword stage on raw text is deliberate and matches the
    /// reference. The patterns are authored against what a user says, so
    /// folding `memories -> memory` under them would silently retarget every
    /// rule that names a plural.
    ///
    /// Lowercased and trimmed before matching, exactly as the Stage 0 this
    /// replaces did, and the patterns are case-insensitive as well.
    /// Not `private`: when `arbitration` is `.ruleOnly` the rule's own intent is
    /// the one fact a report needs and cannot otherwise obtain — the TSV shows
    /// the model's label and the final label, and the rule's label sits between
    /// them, invisible.
    func firstKeywordIntent(_ text: String) -> String? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        return keywordRules.first { $0.matches(t) }?.intent
    }

    func oovRatio(_ text: String) async -> Double {
        await classifier.oovRatio(text)
    }

    /// Non-zero feature count for this utterance — observability only, nothing
    /// in the decision path reads it. See `PackTFIDFVectorizer.featureCount(_:)`.
    func featureCount(_ text: String) async -> Int {
        await classifier.featureCount(text)
    }

    func calibratedConfidence(for intent: String) async -> Double? {
        await classifier.calibratedConfidence(for: intent)
    }

    /// VIK-055. Arbitrate the keyword rules against the model, mirroring
    /// `classifier.py::classify`.
    ///
    /// The model runs on EVERY turn and is the sole author of the confidence this
    /// returns. The rule, when one fires, is the sole author of the label.
    /// Separating those two responsibilities is the point:
    ///
    ///   * a rule is a deliberate, hand-authored product decision about what an
    ///     utterance means, so it decides the LABEL;
    ///   * only the model produces a calibrated probability, and confidence is
    ///     compared downstream against thresholds fitted on exactly that scale,
    ///     so it decides the NUMBER.
    ///
    /// This lives HERE, not in `NLUEngine`, because that is where the reference
    /// puts it — and because the engine's callers inject stub classifiers, which
    /// ARE the classifier and therefore bypass arbitration entirely. Putting it in
    /// the engine would make every stub a permanent disagreement with the pack.
    ///
    /// Two callers benefit, not one: `handleNewIntent` and the VIK-038
    /// topic-switch probe in `handleSlotFilling`. The reference's probe calls this
    /// same arbitrated path (`engine.py`'s `self.classifier.classify`), so the
    /// probe moves into parity rather than out of it. A contested probe now scores
    /// 0.60, under the 0.68 interrupt bar, so it no longer abandons a flow the
    /// user is halfway through on a signal measured at ~45% correct.
    ///
    /// Cost: one extra inference on the ~9% of turns that hit a rule; the rest
    /// already ran the model. The reference measured that arm at 0.06 ms.
    func classifyAsync(_ text: String) async -> ClassificationResult {
        let keywordIntent = firstKeywordIntent(text)
        let prediction = await classifier.classify(text)

        // A vacuous prediction is not a low-confidence one: nothing in the
        // utterance matched the vocabulary, so the scores are the model's
        // priors. Route it out of scope rather than let the engine act on a
        // number that means nothing (VIK-011).
        //
        // A rule that fired is deliberately NOT honoured here. A model that read
        // no features cannot corroborate anything, so the honest outcomes are
        // "contested" or nothing — and contested (0.60) is below the fire bar, so
        // both land on the fallback. Returning out-of-scope says the same thing
        // without implying the two stages were compared. Android reaches the same
        // fallback by the contested route.
        guard !prediction.isVacuous else {
            return ClassificationResult(
                label: outOfScopeIntent,
                confidence: 0,
                semanticRescue: false,
                breakdown: ClassificationBreakdown(winningStage: nil, stage2: nil, stage3: nil))
        }

        // The MODEL's own reading, recorded whichever way arbitration goes — the
        // debug panel wants what the model said, and `NLUEngine`'s decision log
        // reads it to show both sides of a disagreement.
        let stage2 = ClassificationBreakdown.StageResult(
            stage: 2, intent: prediction.intent, confidence: prediction.confidence)

        guard let keywordIntent else {
            return ClassificationResult(
                label: prediction.intent,
                confidence: prediction.confidence,
                semanticRescue: false,
                breakdown: ClassificationBreakdown(
                    winningStage: prediction.passesGate ? 2 : nil,
                    stage2: stage2,
                    stage3: nil))
        }

        // THREE outcomes, not two. `winningStage: 1` throughout — the keyword rule
        // decided the label, and 1 is what that field has always meant (see
        // `ClassificationBreakdown.StageResult`).
        //
        // The two-way split (agree / disagree) is what the Python reference and
        // Android ship, and measuring it on this pack's own honest holdout is
        // what showed it is wrong here: of the 20 contested turns, 18 were
        // correct under the old bypass and only 9 survive a flat "disagreement
        // means ambiguity" rule. The losses are all the same shape — a rule
        // authored for a phrasing the model reads badly:
        //
        //     "dim the audio"               rule VolumeDecrease   model StreamingStart
        //     "load my normal configuration" rule MemoryChange     model VolumeUnmute
        //     "voices seem distant to me"    rule VolumeIncrease   model Help_Home
        //
        // What the defect case looks like is DIFFERENT, and that difference is
        // the whole discriminator: there the model does not name another intent,
        // it says the utterance is out of scope.
        //
        //     "who is the prime minister of create reminder"
        //                                    rule reminders.add   model <fallback>
        //
        // So the model only overrules a rule when it recognises NOTHING. Measured
        // across 1470 turns: two-way costs 10 correct turns, three-way costs 1,
        // and both fix the defect. Neither changes `wrong_action_count` (5).
        //
        // TEMPERATURE-INVARIANT, which is why this survives the CoreML/reference
        // confidence drift: every branch below compares argmax labels, never a
        // confidence. Only the fire test downstream reads the number.
        if keywordIntent == prediction.intent {
            return ClassificationResult(
                label: keywordIntent,
                confidence: prediction.confidence,
                semanticRescue: false,
                breakdown: ClassificationBreakdown(winningStage: 1, stage2: stage2, stage3: nil),
                arbitration: .corroborated)
        }

        // `outOfScopeIntent` is "" for a pack that declares no fallback label. An
        // empty string never equals a predicted intent, so such a pack simply
        // never reaches the contested branch — the rule keeps winning, which is
        // the pre-VIK-055 behaviour and the safe direction to degrade in.
        if !outOfScopeIntent.isEmpty, prediction.intent == outOfScopeIntent {
            return ClassificationResult(
                label: keywordIntent,
                confidence: Self.contestedConfidence,
                semanticRescue: false,
                breakdown: ClassificationBreakdown(winningStage: 1, stage2: stage2, stage3: nil),
                arbitration: .contested)
        }

        return ClassificationResult(
            label: keywordIntent,
            confidence: Self.ruleOnlyConfidence,
            semanticRescue: false,
            breakdown: ClassificationBreakdown(winningStage: 1, stage2: stage2, stage3: nil),
            arbitration: .ruleOnly)
    }

    func warmUp() async { await classifier.warmUp() }

    /// Stage 3 is pack-gated. A host asking for it when the pack disables it is
    /// asking for behaviour the pack's accuracy numbers were not measured under,
    /// so the request is ignored rather than honoured.
    func loadStage3() async {
        guard semanticEnabled else { return }
    }

    func releaseStage3() async { await classifier.unload() }
}
