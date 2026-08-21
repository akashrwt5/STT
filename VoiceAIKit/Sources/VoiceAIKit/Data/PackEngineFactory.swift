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
            schema: schema(from: pack),
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
            trailingFunctionWords: effectiveTrailingWords,
            leadingConnectors: lexicon.leadingConnectors,
            confirmationGates: confirmationGates(from: pack))

        log.info("""
            Engine ready — \(pack.manifest.bundleID, privacy: .public) \
            [\(pack.language, privacy: .public)], \(pack.intents.count) intents, \
            \(pack.classifier.variant.rawValue, privacy: .public) head
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
    static func schema(from pack: ResolvedPack) -> NLUSchema {
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
                let done = workflow.completion.flatMap { pack.responses[$0.response] } ?? ""
                followup = FollowupDef(
                    context: id,
                    lifespan: 1,
                    prompt: prompt,
                    yes: FollowupBranch(action: workflow.completion?.action ?? "", fulfillment: done),
                    // The pack has no cancel text per intent; the confirm-gate's
                    // shared message is `sys.confirm.cancelled`.
                    no: FollowupBranch(action: "", fulfillment: pack.responses["sys.confirm.cancelled"] ?? ""))
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

    private let classifier: PackIntentClassifier
    private let outOfScopeIntent: String
    /// The pack decides whether semantic rescue runs — not the host, and not
    /// this adapter. en packs ship it disabled and their report card was
    /// measured that way.
    private let semanticEnabled: Bool

    init(pack: ResolvedPack) throws {
        self.classifier = try PackIntentClassifier(artifacts: pack.classifier)
        self.outOfScopeIntent = pack.outOfScopeIntent ?? ""
        self.semanticEnabled = pack.stageEnabled(.semantic)
    }

    func classifyAsync(_ text: String) async -> ClassificationResult {
        let prediction = await classifier.classify(text)

        // A vacuous prediction is not a low-confidence one: nothing in the
        // utterance matched the vocabulary, so the scores are the model's
        // priors. Route it out of scope rather than let the engine act on a
        // number that means nothing (VIK-011).
        guard !prediction.isVacuous else {
            return ClassificationResult(
                label: outOfScopeIntent,
                confidence: 0,
                semanticRescue: false,
                breakdown: ClassificationBreakdown(winningStage: nil, stage2: nil, stage3: nil))
        }

        let stage2 = ClassificationBreakdown.StageResult(
            stage: 2, intent: prediction.intent, confidence: prediction.confidence)
        return ClassificationResult(
            label: prediction.intent,
            confidence: prediction.confidence,
            semanticRescue: false,
            breakdown: ClassificationBreakdown(
                winningStage: prediction.passesGate ? 2 : nil,
                stage2: stage2,
                stage3: nil))
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
