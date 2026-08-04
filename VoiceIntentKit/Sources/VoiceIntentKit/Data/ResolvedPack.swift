// ResolvedPack.swift
// VoiceIntentKit
//
// One pack, verified, parsed, joined and bound to a single language. Immutable.
//
// This is the flattened form. The v3 surface on disk is normalized across ~43
// files so that structure and strings stay separate — that separation is what
// makes a second language a new `responses/<lang>.json` instead of a new schema.
// But a runtime wants one table, so the join happens here, ONCE, at load, AFTER
// the language is known.
//
// That ordering is the whole point. Flattening is language-binding: the moment
// you inline a prompt into an intent you have chosen a language. The pack also
// ships a pre-flattened `nlu_schema.json`, which is the compiler doing this same
// join one layer too early — and it loses `contractions`, the datetime grammar,
// the confirmation policy, keyword tiers and 9 keyword rules on the way.
//
// TWO INVARIANTS, both violated by the code this replaces:
//
//  1. `ResolvedPack` is the ONLY source of runtime behaviour. No Swift constant
//     may supply a word list, threshold, prompt or regex. Absent from the pack
//     means throw, not default.
//  2. VoiceIntentKit never INTERPRETS an intent label. Labels are opaque strings
//     routed by pack data. That is what makes the taxonomy replaceable and what
//     let `Cmd.*` be removed without touching the engine.

import Foundation

public struct ResolvedPack: Sendable {

    // MARK: Identity

    public let manifest: NLUBundle
    /// The language this instance is bound to. A pack may declare several; a
    /// `ResolvedPack` is always exactly one.
    public let language: String
    /// Absolute location on disk. Artifact paths resolve against it.
    public let root: URL

    // MARK: Dialog

    /// Intent id → workflow. Union of every capability's `workflows.json`.
    public let intents: [String: IntentWorkflow]
    /// Response key → localized string, for `language`. Every key referenced by
    /// a workflow is present; the loader fails if one is not.
    public let responses: [String: String]
    /// Action key → the capability that owns it.
    public let actionOwners: [String: String]
    /// Entity id → canonical value → synonyms, already resolved for `language`.
    public let entities: [String: [String: [String]]]
    /// Entity ids the runtime must supply at match time (`sys.date_time`).
    public let dynamicEntities: Set<String>
    /// Entity ids where approximate matching is permitted. Carried separately
    /// because `entities` is flattened to synonyms and would otherwise lose the
    /// flag — and silently disabling fuzzy matching makes a slot simply stop
    /// filling for a mistyped memory name, with nothing to trace.
    public let fuzzyEntities: Set<String>
    /// Entity ids whose value list is a hint rather than a closed set, so a
    /// free-text answer is acceptable. Same reasoning as `fuzzyEntities`: a flag
    /// that does not survive the flatten is a flag that does not exist.
    ///
    /// Empty for a pack built before the compiler emitted `open` (VIK-017), in
    /// which case free-text slots will not fill — visible as a re-prompt loop,
    /// which is why `PackSlotResolver` logs it rather than leaving it to be
    /// discovered.
    public let openEntities: Set<String>
    /// Dynamic entity id → `dynamic_source`. Lets the runtime dispatch on what
    /// the pack SAYS an entity is rather than on how its id is spelled
    /// (VIK-019). Pre-fix packs carry the unqualified `runtime.builtin`.
    public let builtinSources: [String: String]

    // MARK: Language data

    public let lexicon: PackLexicon
    public let keywordRules: [PackKeywords.Rule]

    // MARK: Runtime tables

    public let policies: PackPolicies
    public let cascade: PackCascade
    public let routing: PackRouting
    public let guards: PackGuards
    public let telemetry: PackTelemetrySchema

    // MARK: Classifier

    public let classifier: ClassifierArtifacts

    /// Everything needed to stand up the intent classifier, with paths already
    /// resolved to absolute URLs.
    public struct ClassifierArtifacts: Sendable {
        /// Which head was bound. The model, the vocabulary behind `weightsURL`
        /// and `temperature` are all this variant's — they are one triple and
        /// cannot be mixed.
        public let variant: ClassifierVariant
        /// Label space. Index is positional and must match the coefficient rows.
        public let labels: [String]
        /// `.mlmodelc` (pre-compiled) or `.mlpackage` (needs compiling), nil if
        /// the pack ships no CoreML head.
        public let model: ModelArtifact?
        /// TF-IDF + LogReg weights, the pure-Swift fallback and the source of
        /// the vocab/idf used to vectorise input for the CoreML head.
        public let weightsURL: URL
        /// Confidence calibration. `softmax(logits / temperature)`.
        public let temperature: Double
        public let confidenceThreshold: Double
        public let confidenceGapThreshold: Double

        public struct ModelArtifact: Sendable {
            public let url: URL
            /// True for `.mlmodelc`. Decides which CoreML API is legal:
            /// `MLModel(contentsOf:)` REQUIRES a compiled model and
            /// `MLModel.compileModel(at:)` REJECTS one, so this is a dispatch
            /// flag, not a hint.
            public let isCompiled: Bool
        }
    }
}

// MARK: - Queries

extension ResolvedPack {

    /// Resolve a response key to text. Nil only for a key not in the catalog —
    /// which the loader has already proven cannot happen for keys reachable
    /// from a workflow.
    public func text(for key: String) -> String? { responses[key] }

    /// Confirmation policy for an intent. Unknown intents are `never`: an intent
    /// with no policy is one the pack does not gate.
    public func confirmationPolicy(for intent: String) -> ConfirmationPolicy {
        ConfirmationPolicy(rawValue: policies.confirmation[intent] ?? "never") ?? .never
    }

    public enum ConfirmationPolicy: String, Sendable {
        case always, never
        case whenAmbiguous = "when_ambiguous"
    }

    /// The confirmation band. `confirmationPolicy` says WHICH intents are gated;
    /// this says WHEN. Nil when the pack omits the scalars, in which case a
    /// runtime must not invent a band — it should treat `when_ambiguous` as
    /// `never` and say so.
    public var uncertainConfirmBand: (floor: Double, ceiling: Double)? {
        guard let below = policies.thresholds.uncertainConfirmBelow,
              let floor = policies.thresholds.uncertainConfirmFloor else { return nil }
        return (floor: floor, ceiling: below)
    }

    /// Whether a cascade stage runs. The PACK decides, not host configuration:
    /// en-1.0.28 disables the semantic stage, and the report card that gates
    /// release was measured with it off.
    public func stageEnabled(_ stage: Stage) -> Bool { cascade.isEnabled(stage.rawValue) }

    public enum Stage: String, Sendable {
        case keyword, tfidf, semantic, fallback
    }

    /// The help-marker redirect for a classified intent, when the utterance
    /// matched the marker pattern. Nil when there is no guard for it.
    public func helpRedirect(for intent: String) -> String? {
        guards.helpMarker?.pairs[intent]
    }

    /// Keyword rules ordered tier 1 (exact anchors) before tier 2.
    public var keywordRulesByTier: [PackKeywords.Rule] {
        keywordRules.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return lhs.intent < rhs.intent
        }
    }

    /// Every intent the pack can produce.
    public var intentIDs: Set<String> { Set(intents.keys) }

    /// The pack's out-of-scope label, discovered rather than hardcoded. The old
    /// code compared against the literal "Default Fallback Intent" in four
    /// places; the taxonomy has since changed twice.
    public var outOfScopeIntent: String? {
        classifier.labels.first { $0.hasSuffix(".oos.fallback") || $0 == "sys.oos.fallback" }
    }

    /// One slot to collect, with its prompt already resolved to text.
    ///
    /// A named struct, not a tuple: a `compactMap` returning a labelled tuple is
    /// one of the shapes that makes Swift's type checker time out.
    public struct ResolvedSlot: Sendable {
        public let spec: IntentWorkflow.SlotSpec
        public let prompt: String
    }

    /// Slots to collect for an intent, in pack order. The loader has already
    /// proven every prompt key resolves, so nothing is dropped here in practice.
    public func slots(for intent: String) -> [ResolvedSlot] {
        guard let specs = intents[intent]?.slots else { return [] }
        var out: [ResolvedSlot] = []
        out.reserveCapacity(specs.count)
        for spec in specs {
            guard let prompt = responses[spec.prompt] else { continue }
            out.append(ResolvedSlot(spec: spec, prompt: prompt))
        }
        return out
    }
}
