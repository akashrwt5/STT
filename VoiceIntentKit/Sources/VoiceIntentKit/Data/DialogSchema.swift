// DialogSchema.swift
// VoiceIntentKit
//
// The intent → slot / fulfillment / follow-up tables `NLUEngine` runs on.
//
// Was `NLU/NLUCore/NLUSchema.swift`, a typed model of `nlu_schema.json` that
// loaded itself from `Bundle.module` and `fatalError`ed if the file was missing.
// It now lives in `Data/` because that is what it became: a projection of a
// pack, built by `PackEngineFactory.schema(from:)`. Nothing decodes it from JSON
// any more.
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
public struct SlotDef: Sendable {
    public let name: String
    /// Entity id, verbatim from the pack. Never interpreted here: whether it is
    /// a gazetteer or a builtin is `SlotResolving`'s question, and matching it
    /// against a literal is how VIK-018 happened.
    public let entity: String
    public let required: Bool
    /// Prompt text, already resolved from the pack's response catalog for this
    /// language.
    public let prompt: String

    public init(name: String, entity: String, required: Bool, prompt: String) {
        self.name = name
        self.entity = entity
        self.required = required
        self.prompt = prompt
    }
}

/// A yes/no branch of a confirmation.
public struct FollowupBranch: Sendable {
    public let action: String
    public let fulfillment: String

    public init(action: String, fulfillment: String) {
        self.action = action
        self.fulfillment = fulfillment
    }
}

/// A yes/no confirmation.
///
/// Whether it actually fires is NOT decided here — see `ConfirmationGate`. The
/// pack carries the question in a workflow and the policy in
/// `runtime/policies.json`, and reading the first as if it were the second is
/// VIK-021: all 14 gated intents confirmed unconditionally, and the two with
/// slots skipped collection entirely.
public struct FollowupDef: Sendable {
    public let context: String
    public let lifespan: Int
    public let prompt: String
    public let yes: FollowupBranch
    public let no: FollowupBranch

    public init(context: String, lifespan: Int, prompt: String,
                yes: FollowupBranch, no: FollowupBranch) {
        self.context = context
        self.lifespan = lifespan
        self.prompt = prompt
        self.yes = yes
        self.no = no
    }
}

/// One intent: its slots, action, fulfillment text, optional confirmation.
public struct IntentDef: Sendable {
    public let slots: [SlotDef]
    public let action: String?
    public let fulfillment: String?
    public let followup: FollowupDef?

    public init(slots: [SlotDef], action: String?, fulfillment: String?, followup: FollowupDef?) {
        self.slots = slots
        self.action = action
        self.fulfillment = fulfillment
        self.followup = followup
    }
}

/// A declarative regex rule that short-circuits classification (Stage 0).
public struct KeywordTrigger: Sendable {
    public let intent: String
    public let regex: String?
    public let notRegex: String?

    public init(intent: String, regex: String?, notRegex: String?) {
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
public struct NLUSchema: Sendable {
    public let version: Int
    public let confidenceThreshold: Double
    public let intents: [String: IntentDef]
    public let affirmative: [String]
    public let negative: [String]
    /// Triggers evaluated before the classifier.
    public let keywordTriggers: [KeywordTrigger]

    public init(version: Int,
                confidenceThreshold: Double,
                intents: [String: IntentDef],
                affirmative: [String],
                negative: [String],
                keywordTriggers: [KeywordTrigger]) {
        self.version = version
        self.confidenceThreshold = confidenceThreshold
        self.intents = intents
        self.affirmative = affirmative
        self.negative = negative
        self.keywordTriggers = keywordTriggers
    }
}
