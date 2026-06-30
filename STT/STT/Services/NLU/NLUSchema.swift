// NLUSchema.swift
// STT
//
// Typed model of nlu_schema.json — the intent → slot/fulfillment/follow-up
// definitions that drive the multi-turn conversation engine.
// Mirrors IntentClassifier/data/nlu_schema.json.

import Foundation

/// One slot to be collected for an intent (e.g. REMINDER needs `name` + `date-time`).
public struct SlotDef: Decodable, Sendable {
    public let name: String
    public let entity: String
    public let required: Bool
    public let prompt: String
}

/// A yes/no branch in a follow-up confirmation.
public struct FollowupBranch: Decodable, Sendable {
    public let action: String
    public let fulfillment: String
}

/// A yes/no confirmation follow-up (e.g. PUSH_TO_TALK → "Do you want to send this message?").
public struct FollowupDef: Decodable, Sendable {
    public let context: String
    public let lifespan: Int
    public let prompt: String
    public let yes: FollowupBranch
    public let no: FollowupBranch
}

/// Definition for a single intent: its slots, action, fulfillment text, optional follow-up.
public struct IntentDef: Decodable, Sendable {
    public let slots: [SlotDef]
    public let action: String?
    public let fulfillment: String?
    public let followup: FollowupDef?

    enum CodingKeys: String, CodingKey {
        case slots, action, fulfillment, followup
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decodeIfPresent([SlotDef].self, forKey: .slots) ?? []
        action = try c.decodeIfPresent(String.self, forKey: .action)
        fulfillment = try c.decodeIfPresent(String.self, forKey: .fulfillment)
        followup = try c.decodeIfPresent(FollowupDef.self, forKey: .followup)
    }
}

/// A declarative regex rule that short-circuits TF-IDF classification.
/// Mirrors `keyword_triggers` entries in nlu_schema.json / nlu_schema.<lang>.json.
public struct KeywordTrigger: Decodable, Sendable {
    public let intent: String
    public let regex: String?
    public let notRegex: String?

    enum CodingKeys: String, CodingKey {
        case intent, regex
        case notRegex = "not_regex"
    }
}

/// The whole conversation schema, loaded once from `nlu_schema.json`.
public struct NLUSchema: Decodable, Sendable {
    public let version: Int
    public let confidenceThreshold: Double
    public let intents: [String: IntentDef]
    public let affirmative: [String]
    public let negative: [String]
    /// Declarative triggers that fire before the TF-IDF classifier.
    public let keywordTriggers: [KeywordTrigger]

    enum CodingKeys: String, CodingKey {
        case version
        case confidenceThreshold = "confidence_threshold"
        case intents, affirmative, negative
        case keywordTriggers = "keyword_triggers"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version              = try c.decode(Int.self, forKey: .version)
        confidenceThreshold  = try c.decode(Double.self, forKey: .confidenceThreshold)
        intents              = try c.decode([String: IntentDef].self, forKey: .intents)
        affirmative          = try c.decode([String].self, forKey: .affirmative)
        negative             = try c.decode([String].self, forKey: .negative)
        keywordTriggers      = (try? c.decodeIfPresent([KeywordTrigger].self, forKey: .keywordTriggers)) ?? []
    }

    /// Loads `nlu_schema.json` from the main app bundle.
    public static func loadFromBundle() -> NLUSchema {
        guard
            let url = Bundle.main.url(forResource: "nlu_schema", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            fatalError("NLUSchema: nlu_schema.json not found in app bundle.")
        }
        do {
            return try JSONDecoder().decode(NLUSchema.self, from: data)
        } catch {
            fatalError("NLUSchema: failed to decode nlu_schema.json — \(error)")
        }
    }
}
