// PackSections.swift
// VoiceIntentKit
//
// Decoders for the v3 normalized surface: capabilities, runtime tables,
// lexicon, keywords, entities.
//
// WHY v3 AND NOT THE ROOT SHIM
// Every pack also ships a flattened `nlu_schema.json` / `nlu_entities.json`
// that roughly matches what this package used to read. We do not touch it. It
// inlines English into every `fulfillment`, slot `prompt` and entity value, so a
// French pack would be a wholly separate file with no structural sharing — the
// exact trap the old `LocalizationLoader` (merge French strings onto an English
// base) was built around. It also drops `contractions`, the whole datetime
// grammar, the per-intent confirmation policy, keyword tiers and 9 keyword
// rules. v3 keeps structure and strings apart, which is the thing that makes
// more than one language possible.
//
// DECODING IS STRICT. A missing key throws. The predecessor decoded with
// `try? … ?? []` and produced an empty struct from a wrong-shaped file, which is
// how a French session could quietly run English word-lists.

import Foundation

// MARK: - capabilities/<id>/capability.json

public struct CapabilityManifest: Decodable, Sendable {
    public let id: String
    public let version: String
    public let status: String
    public let owner: String
    public let platforms: [String]
    public let languages: [String]
    public let actions: [Action]

    public struct Action: Decodable, Sendable {
        public let key: String
        public let descriptor: String
        public let params: [Param]

        public struct Param: Decodable, Sendable {
            public let name: String
            /// "entity_ref" today. The vocabulary is the capability schema's,
            /// not ours, so it stays a string.
            public let type: String
            /// Entity id backing this parameter, when `type` is an entity ref.
            public let entity: String?
            public let required: Bool

            enum CodingKeys: String, CodingKey { case name, type, entity, required }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                type = try c.decode(String.self, forKey: .type)
                entity = try c.decodeIfPresent(String.self, forKey: .entity)
                required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
            }
        }
    }
}

// MARK: - capabilities/<id>/workflows.json

public struct CapabilityWorkflows: Decodable, Sendable {
    public let intents: [String: IntentWorkflow]
}

/// One intent's dialog shape. `response`/`prompt` fields are response KEYS, not
/// text — the string lives in `responses/<lang>.json`. That indirection is what
/// makes a new language a new responses file instead of a new schema.
public struct IntentWorkflow: Decodable, Sendable {
    public let slots: [SlotSpec]
    public let completion: Completion?
    public let confirmation: Confirmation?

    enum CodingKeys: String, CodingKey { case slots, completion, confirmation }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decodeIfPresent([SlotSpec].self, forKey: .slots) ?? []
        completion = try c.decodeIfPresent(Completion.self, forKey: .completion)
        confirmation = try c.decodeIfPresent(Confirmation.self, forKey: .confirmation)
    }

    public struct Completion: Decodable, Sendable {
        public let action: String
        public let response: String
    }

    public struct Confirmation: Decodable, Sendable {
        public let prompt: String
        public let required: Bool
    }

    public struct SlotSpec: Decodable, Sendable {
        public let name: String
        public let entity: String
        public let required: Bool
        /// Response key for the question that collects this slot.
        public let prompt: String
    }
}

// MARK: - runtime/policies.json

public struct PackPolicies: Decodable, Sendable {
    public let policySchema: Int
    public let policyContent: Int
    /// intent id → "always" | "never" | "when_ambiguous"
    public let confirmation: [String: String]
    public let thresholds: Thresholds
    public let limits: Limits

    enum CodingKeys: String, CodingKey {
        case policySchema = "policy_schema"
        case policyContent = "policy_content"
        case confirmation, thresholds, limits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policySchema = try c.decode(Int.self, forKey: .policySchema)
        policyContent = try c.decode(Int.self, forKey: .policyContent)
        confirmation = try c.decode([String: String].self, forKey: .confirmation)
        thresholds = try c.decode(Thresholds.self, forKey: .thresholds)
        limits = try c.decodeIfPresent(Limits.self, forKey: .limits) ?? Limits()
    }

    public struct Thresholds: Decodable, Sendable {
        public let confidence: Double
        public let interrupt: Double
        public let semantic: Double
        public let agreement: Double?
        /// Upper bound of the confirmation band. `confirmation` says WHICH
        /// intents are gated; these two say WHEN. Without them a runtime knows
        /// the gated set but not the band, so it confirms always or never —
        /// both wrong.
        public let uncertainConfirmBelow: Double?
        /// Lower bound. Under this the utterance is too weak to confirm and
        /// falls through to the routing ladder.
        public let uncertainConfirmFloor: Double?

        enum CodingKeys: String, CodingKey {
            case confidence, interrupt, semantic, agreement
            case uncertainConfirmBelow = "uncertain_confirm_below"
            case uncertainConfirmFloor = "uncertain_confirm_floor"
        }
    }

    public struct Limits: Decodable, Sendable {
        public let maxSlotAttempts: Int
        public let sessionTimeoutSeconds: Int
        public let maxFollowupDepth: Int?

        enum CodingKeys: String, CodingKey {
            case maxSlotAttempts = "max_slot_attempts"
            case sessionTimeoutSeconds = "session_timeout_s"
            case maxFollowupDepth = "max_followup_depth"
        }

        public init() { maxSlotAttempts = 3; sessionTimeoutSeconds = 120; maxFollowupDepth = nil }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            maxSlotAttempts = try c.decodeIfPresent(Int.self, forKey: .maxSlotAttempts) ?? 3
            sessionTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .sessionTimeoutSeconds) ?? 120
            maxFollowupDepth = try c.decodeIfPresent(Int.self, forKey: .maxFollowupDepth)
        }
    }
}

// MARK: - runtime/cascade.json

/// Stage wiring. The pack is authoritative over host configuration: en-1.0.28
/// disables the semantic stage, and a host asking for semantic rescue must not
/// override a decision the pack's report card was measured under.
public struct PackCascade: Decodable, Sendable {
    public let stages: [Stage]

    public struct Stage: Decodable, Sendable {
        public let id: String
        public let enabled: Bool
        public let input: IO?
        public let output: IO?

        public struct IO: Decodable, Sendable {
            public let dtype: String?
            public let dim: Int?
            public let shape: [Int]?
        }
    }

    public func isEnabled(_ id: String) -> Bool {
        stages.first { $0.id == id }?.enabled ?? false
    }

    /// Declared output width of the tfidf stage — cross-checked against the
    /// label count so a model and a label file from different runs cannot pair.
    ///
    /// Note the *input* contract here describes the server ONNX graph
    /// (`{dtype: string, shape: [1]}`), not the device CoreML head, which takes
    /// a dense float32 vector. Do not validate the device model against it.
    public var tfidfOutputDim: Int? {
        stages.first { $0.id == "tfidf" }?.output?.dim
    }
}

// MARK: - runtime/routing.json

public struct PackRouting: Decodable, Sendable {
    public let ladder: [Step]
    public let assistCloud: AssistCloud?

    enum CodingKeys: String, CodingKey {
        case ladder
        case assistCloud = "assist_cloud"
    }

    public struct Step: Decodable, Sendable {
        public let step: String
        public let when: When
        public let budgetPerSession: Int?

        enum CodingKeys: String, CodingKey {
            case step, when
            case budgetPerSession = "budget_per_session"
        }

        public struct When: Decodable, Sendable {
            public let belowConfidence: Double?
            public let afterAttempts: Int?
            public let requiresFeature: String?
            public let requiresConsent: Bool?

            enum CodingKeys: String, CodingKey {
                case belowConfidence = "below_confidence"
                case afterAttempts = "after_attempts"
                case requiresFeature = "requires_feature"
                case requiresConsent = "requires_consent"
            }
        }
    }

    public struct AssistCloud: Decodable, Sendable {
        public let enabled: Bool
        public let timeoutMS: Int?

        enum CodingKeys: String, CodingKey {
            case enabled
            case timeoutMS = "timeout_ms"
        }
    }
}

// MARK: - runtime/guards.json

/// Corrections applied to a classified intent BEFORE the dispatcher sees it.
/// Distinct from routing: routing decides what to do when confidence is LOW,
/// a guard fires regardless of confidence.
///
/// Additive section — a pack without it simply has no guards.
public struct PackGuards: Decodable, Sendable {
    public let helpMarker: HelpMarker?
    public let polarity: [PolarityGuard]

    enum CodingKeys: String, CodingKey {
        case helpMarker = "help_marker"
        case polarity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        helpMarker = try c.decodeIfPresent(HelpMarker.self, forKey: .helpMarker)
        polarity = try c.decodeIfPresent([PolarityGuard].self, forKey: .polarity) ?? []
    }

    public static let empty = PackGuards()
    private init() { helpMarker = nil; polarity = [] }

    /// Redirects a command to its help counterpart when the utterance is a
    /// question about it — "how do i turn up the volume" must show help, not
    /// change the volume.
    public struct HelpMarker: Decodable, Sendable {
        public let markers: String
        /// classified intent → help intent to substitute.
        public let pairs: [String: String]
    }

    public struct PolarityGuard: Decodable, Sendable {
        public let intent: String
        public let pattern: String
        /// Absent means suppress to the out-of-scope fallback.
        public let redirect: String?
    }
}

// MARK: - keywords/<lang>.json

public struct PackKeywords: Decodable, Sendable {
    public let lang: String
    public let rules: [Rule]

    /// Tier 1 is an exact anchored match (`^mute$`), tier 2 a looser pattern.
    /// The flattened root shim drops the tier and 9 of these rules entirely.
    public struct Rule: Decodable, Sendable {
        public let intent: String
        public let pattern: String
        public let tier: Int
        /// Patterns that VETO the match — the utterance looks like this intent
        /// but a guard word says otherwise.
        public let guards: [String]

        enum CodingKeys: String, CodingKey { case intent, pattern, tier, guards }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            intent = try c.decode(String.self, forKey: .intent)
            pattern = try c.decode(String.self, forKey: .pattern)
            tier = try c.decodeIfPresent(Int.self, forKey: .tier) ?? 2
            guards = try c.decodeIfPresent([String].self, forKey: .guards) ?? []
        }
    }
}

// MARK: - entities/shared/content.json

public struct PackEntities: Decodable, Sendable {
    public let entities: [String: EntityDefinition]
}

/// Values are LANGUAGE-KEYED (`{"en": [...]}`). In a per-language pack that map
/// has exactly one key, but reading it by language rather than taking the first
/// value is what keeps the code honest if that ever changes.
public struct EntityDefinition: Decodable, Sendable {
    public let type: String
    public let fuzzy: Bool
    /// The value list is a hint, not a closed set — a free-text answer is
    /// acceptable and the runtime may derive one from the utterance.
    ///
    /// Added to the format in response to VIK-017: the flag existed upstream and
    /// was dropped by the v3 projection, so `remind` looked closed and could not
    /// be filled from free text. `decodeIfPresent` because packs built before
    /// that fix do not carry it — absent means closed, which is the safe reading.
    public let open: Bool
    public let values: [String: [String: [String]]]
    /// `runtime.builtin.datetime`, `runtime.builtin.integer`, or the bare
    /// `runtime.builtin` from a pack built before VIK-019.
    public let dynamicSource: String?

    enum CodingKeys: String, CodingKey {
        case type, fuzzy, open, values
        case dynamicSource = "dynamic_source"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        fuzzy = try c.decodeIfPresent(Bool.self, forKey: .fuzzy) ?? false
        open = try c.decodeIfPresent(Bool.self, forKey: .open) ?? false
        values = try c.decodeIfPresent([String: [String: [String]]].self, forKey: .values) ?? [:]
        dynamicSource = try c.decodeIfPresent(String.self, forKey: .dynamicSource)
    }

    /// Canonical value → synonyms, for one language. Throws nothing: an entity
    /// with no entry for this language yields an empty table, which the loader
    /// reports rather than silently accepting.
    public func synonyms(language: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (canonical, byLang) in values {
            if let syns = byLang[language] { out[canonical] = syns }
        }
        return out
    }

    public var isDynamic: Bool { type == "dynamic" }
}

// MARK: - telemetry/schema.json

/// Enums only — the pack publishes the closed vocabularies, not the event
/// shape. Values are validated against these before emission so a client cannot
/// invent a stage or outcome name the backend will reject.
public struct PackTelemetrySchema: Decodable, Sendable {
    public let telemetrySchemaVersion: Int
    public let enums: Enums

    enum CodingKeys: String, CodingKey {
        case telemetrySchemaVersion = "telemetry_schema_version"
        case enums
    }

    public struct Enums: Decodable, Sendable {
        public let lifecycle: [String]
        public let outcome: [String]
        public let routingReason: [String]
        public let stages: [String]

        enum CodingKeys: String, CodingKey {
            case lifecycle, outcome, stages
            case routingReason = "routing_reason"
        }
    }
}
