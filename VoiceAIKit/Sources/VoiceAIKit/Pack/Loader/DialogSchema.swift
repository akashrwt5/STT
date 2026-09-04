// DialogSchema.swift
// VoiceAIKit
//
// The intent → slot / fulfillment / follow-up tables `NLUEngine` runs on.
//
// Was `NLU/NLUCore/NLUSchema.swift`, a typed model of `nlu_schema.json` that
// loaded itself from `Bundle.module` and `fatalError`ed if the file was missing.
// It now lives in `Pack/Loader/` because that is what it became: a projection
// of a pack, built by `PackEngineFactory.schema(from:)`. Deliberately NOT in
// `Pack/Schema/` — that directory holds the pack's on-disk FORMAT, and this type
// is the factory's OUTPUT, so it is filed next to the only thing that constructs
// it. Nothing decodes it from JSON any more.
//
// THE `Decodable` CONFORMANCES ARE GONE, and that is the substantive change
// rather than a tidy-up. `NLUSchema` and `IntentDef` declared `init(from:)`
// inside the type body, which suppresses Swift's synthesised memberwise
// initialiser — so they could ONLY be decoded from JSON, never constructed in
// code. `PackEngineFactory` had to add memberwise inits back in an extension to
// build them from a pack at all. Those inits are now where they belong, and the
// types can no longer be built from an arbitrary JSON file that nobody verified.
//
// The names keep their `NLU*` spelling because `NLUEngine` reads them and the
// engine is not being rewritten in this change.

import Foundation

/// One slot to collect for an intent — `reminders.task.create` needs `name` and
/// `date_time`.
struct SlotDef: Sendable {
    let name: String
    /// Entity id, verbatim from the pack. Never interpreted here: whether it is
    /// a gazetteer or a builtin is `SlotResolving`'s question, and matching it
    /// against a literal is how VIK-018 happened.
    let entity: String
    let required: Bool
    /// Prompt text, already resolved from the pack's response catalog for this
    /// language.
    let prompt: String

    init(name: String, entity: String, required: Bool, prompt: String) {
        self.name = name
        self.entity = entity
        self.required = required
        self.prompt = prompt
    }
}

/// A yes/no branch of a confirmation: what this answer does, what it says, and
/// what the host calls the outcome.
struct FollowupBranch: Sendable {
    let action: String
    let fulfillment: String
    /// The host's single name for this outcome — the Dialogflow-era
    /// `Cmd.SendMessage - yes`. Nil for a pack whose host reads plain intent
    /// ids, in which case the engine reports the intent unchanged.
    ///
    /// It travels WITH the branch rather than in a lookup beside the engine,
    /// because it is the same fact as the action and the text: what happens when
    /// the question is answered this way. Two artifacts held it before and each
    /// stated half a turn.
    let label: String?

    init(action: String, fulfillment: String, label: String? = nil) {
        self.action = action
        self.fulfillment = fulfillment
        self.label = label
    }
}

/// A yes/no confirmation.
///
/// Whether it actually fires is NOT decided here — see `ConfirmationGate`. The
/// pack carries the question in a workflow and the policy in
/// `runtime/policies.json`, and reading the first as if it were the second is
/// VIK-021: all 14 gated intents confirmed unconditionally, and the two with
/// slots skipped collection entirely.
struct FollowupDef: Sendable {
    let context: String
    let lifespan: Int
    let prompt: String
    let yes: FollowupBranch
    let no: FollowupBranch

    init(context: String, lifespan: Int, prompt: String,
                yes: FollowupBranch, no: FollowupBranch) {
        self.context = context
        self.lifespan = lifespan
        self.prompt = prompt
        self.yes = yes
        self.no = no
    }
}

/// One intent: its slots, action, fulfillment text, optional confirmation.
struct IntentDef: Sendable {
    let slots: [SlotDef]
    let action: String?
    let fulfillment: String?
    let followup: FollowupDef?

    init(slots: [SlotDef], action: String?, fulfillment: String?, followup: FollowupDef?) {
        self.slots = slots
        self.action = action
        self.fulfillment = fulfillment
        self.followup = followup
    }
}

/// A declarative regex rule that short-circuits classification (Stage 0).
struct KeywordTrigger: Sendable {
    let intent: String
    let regex: String?
    let notRegex: String?

    init(intent: String, regex: String?, notRegex: String?) {
        self.intent = intent
        self.regex = regex
        self.notRegex = notRegex
    }
}

/// The whole conversation schema for one language.
///
/// Built by `PackEngineFactory.schema(from:)` from a verified `ResolvedPack`.
/// There is deliberately no way to load one from a file: the previous
/// `loadFromBundle()` read `nlu_schema.json` out of `Bundle.module` and
/// `fatalError`ed when it was absent, which made a missing resource a crash and
/// a WRONG resource silent.
struct NLUSchema: Sendable {

    /// The label a pack uses when the utterance is not one of its intents.
    ///
    /// Kept as a constant rather than inlined because it is a CONTRACT, not a
    /// string: the host dispatches on it, and it is the same name the app's
    /// Dialogflow path has always returned for an unmatched query.
    static let defaultFallbackIntent = "Default Fallback Intent"

    let version: Int
    let confidenceThreshold: Double
    /// The intent name reported when nothing matched — the pack's own
    /// out-of-scope label where it has one, `defaultFallbackIntent` otherwise.
    /// The engine never invents a name; it reports this one.
    let fallbackIntent: String
    let intents: [String: IntentDef]
    let affirmative: [String]
    let negative: [String]
    /// Triggers evaluated before the classifier.
    let keywordTriggers: [KeywordTrigger]

    init(version: Int,
                confidenceThreshold: Double,
                fallbackIntent: String = NLUSchema.defaultFallbackIntent,
                intents: [String: IntentDef],
                affirmative: [String],
                negative: [String],
                keywordTriggers: [KeywordTrigger]) {
        self.version = version
        self.confidenceThreshold = confidenceThreshold
        self.fallbackIntent = fallbackIntent
        self.intents = intents
        self.affirmative = affirmative
        self.negative = negative
        self.keywordTriggers = keywordTriggers
    }
}
