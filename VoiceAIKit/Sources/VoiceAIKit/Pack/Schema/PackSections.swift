// PackSections.swift
// VoiceAIKit
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

struct CapabilityManifest: Decodable, Sendable {
    let id: String
    let version: String
    let status: String
    let owner: String
    let platforms: [String]
    let languages: [String]
    let actions: [Action]

    struct Action: Decodable, Sendable {
        let key: String
        let descriptor: String
        let params: [Param]

        struct Param: Decodable, Sendable {
            let name: String
            /// "entity_ref" today. The vocabulary is the capability schema's,
            /// not ours, so it stays a string.
            let type: String
            /// Entity id backing this parameter, when `type` is an entity ref.
            let entity: String?
            let required: Bool

            enum CodingKeys: String, CodingKey { case name, type, entity, required }

            init(from decoder: Decoder) throws {
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

struct CapabilityWorkflows: Decodable, Sendable {
    let intents: [String: IntentWorkflow]
}

/// One intent's dialog shape. `response`/`prompt` fields are response KEYS, not
/// text — the string lives in `responses/<lang>.json`. That indirection is what
/// makes a new language a new responses file instead of a new schema.
struct IntentWorkflow: Decodable, Sendable {
    let slots: [SlotSpec]
    let completion: Completion?
    let confirmation: Confirmation?

    enum CodingKeys: String, CodingKey { case slots, completion, confirmation }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decodeIfPresent([SlotSpec].self, forKey: .slots) ?? []
        completion = try c.decodeIfPresent(Completion.self, forKey: .completion)
        confirmation = try c.decodeIfPresent(Confirmation.self, forKey: .confirmation)
    }

    struct Completion: Decodable, Sendable {
        let action: String
        let response: String
    }

    struct Confirmation: Decodable, Sendable {
        let prompt: String
        let required: Bool
    }

    struct SlotSpec: Decodable, Sendable {
        let name: String
        let entity: String
        let required: Bool
        /// Response key for the question that collects this slot.
        let prompt: String
    }
}

// MARK: - runtime/policies.json

struct PackPolicies: Decodable, Sendable {
    let policySchema: Int
    let policyContent: Int
    /// intent id → "always" | "never" | "when_ambiguous"
    let confirmation: [String: String]
    let thresholds: Thresholds
    let limits: Limits

    enum CodingKeys: String, CodingKey {
        case policySchema = "policy_schema"
        case policyContent = "policy_content"
        case confirmation, thresholds, limits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policySchema = try c.decode(Int.self, forKey: .policySchema)
        policyContent = try c.decode(Int.self, forKey: .policyContent)
        confirmation = try c.decode([String: String].self, forKey: .confirmation)
        thresholds = try c.decode(Thresholds.self, forKey: .thresholds)
        limits = try c.decodeIfPresent(Limits.self, forKey: .limits) ?? Limits()
    }

    struct Thresholds: Decodable, Sendable {
        let confidence: Double
        let interrupt: Double
        let semantic: Double
        let agreement: Double?
        /// Upper bound of the confirmation band. `confirmation` says WHICH
        /// intents are gated; these two say WHEN. Without them a runtime knows
        /// the gated set but not the band, so it confirms always or never —
        /// both wrong.
        let uncertainConfirmBelow: Double?
        /// Lower bound. Under this the utterance is too weak to confirm at all,
        /// and the turn is decided by the fire threshold like any other.
        let uncertainConfirmFloor: Double?
        /// Out-of-vocabulary guard — BOTH halves, or neither.
        ///
        /// `oovReject` is the share of unrepresentable tokens above which the
        /// turn goes to fallback whatever the confidence. `oovBypass` is the
        /// confidence above which that guard stands down, and it is NOT
        /// optional in the behavioural sense: entity values are out-of-vocabulary
        /// by nature — "send a message to john" is 25% unknown and entirely real —
        /// so the ratio alone refuses commands. The compiler emits the two from
        /// one statement for that reason. Optional only so a pack predating them
        /// still decodes; `NLUEngine` requires both before it applies either.
        let oovReject: Double?
        let oovBypass: Double?

        enum CodingKeys: String, CodingKey {
            case confidence, interrupt, semantic, agreement
            case uncertainConfirmBelow = "uncertain_confirm_below"
            case uncertainConfirmFloor = "uncertain_confirm_floor"
            case oovReject = "oov_reject"
            case oovBypass = "oov_bypass"
        }
    }

    struct Limits: Decodable, Sendable {
        let maxSlotAttempts: Int
        let sessionTimeoutSeconds: Int
        let maxFollowupDepth: Int?

        enum CodingKeys: String, CodingKey {
            case maxSlotAttempts = "max_slot_attempts"
            case sessionTimeoutSeconds = "session_timeout_s"
            case maxFollowupDepth = "max_followup_depth"
        }

        init() { maxSlotAttempts = 3; sessionTimeoutSeconds = 120; maxFollowupDepth = nil }

        init(from decoder: Decoder) throws {
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
struct PackCascade: Decodable, Sendable {
    let stages: [Stage]

    struct Stage: Decodable, Sendable {
        let id: String
        let enabled: Bool
        let input: IO?
        let output: IO?

        struct IO: Decodable, Sendable {
            let dtype: String?
            let dim: Int?
            let shape: [Int]?
        }
    }

    func isEnabled(_ id: String) -> Bool {
        stages.first { $0.id == id }?.enabled ?? false
    }

    /// Declared output width of the tfidf stage — cross-checked against the
    /// label count so a model and a label file from different runs cannot pair.
    ///
    /// Note the *input* contract here describes the server ONNX graph
    /// (`{dtype: string, shape: [1]}`), not the device CoreML head, which takes
    /// a dense float32 vector. Do not validate the device model against it.
    var tfidfOutputDim: Int? {
        stages.first { $0.id == "tfidf" }?.output?.dim
    }
}

// MARK: - runtime/routing.json — deliberately not modelled
//
// There was a `PackRouting` here: `ladder: [Step]` and `assist_cloud`, decoded
// on every load and stored on `ResolvedPack`. NOTHING READ IT. Not one call
// site, in Sources or Tests, ever touched `pack.routing`.
//
// It is gone rather than wired because the file it decoded was never authored.
// The compiler carries `runtime/routing.json` VERBATIM out of a spec example
// (`content_bundle.py`: `CARRIED = (...)`, "Files taken verbatim from the
// fixture"), re-deriving exactly one number in it. So the ladder every pack
// shipped — `reprompt` below 0.7, `give_up` after 3 — was documentation for a
// minimal example, and it contradicted all three of:
//
//   * the engines. Both runtimes are binary below the fire threshold: the
//     reference `engine.py` returns the fallback intent and says so —
//     "The decision ladder is BINARY: `confidence_threshold` and below it the
//     fallback intent." There is no reprompt step in either.
//   * ADR-004, the design. Its ladder is eight rules; `reprompt` is not one of
//     them. Re-prompting is rule 1's MID-FLOW behaviour ("a garbled slot answer
//     is a re-prompt"), which has nothing to do with a confidence threshold.
//     Low confidence is rule 5 (clarify) or rule 6 (escalate).
//   * ADR-005, which assigns this file to the Platform team as the output of a
//     policy-resolution stage that does not exist in this compiler yet.
//
// And `assist_cloud.enabled` is worse than unread: it looks like the switch that
// governs sending an utterance to a cloud LLM. ADR-004 makes consent a per-user,
// revocable AVAILABILITY condition checked at runtime — a fleet-wide signed pack
// cannot express it. A field that reads as a privacy control and controls
// nothing is the one kind of dead config worth deleting rather than tolerating.
//
// Every value the file carried already has a real owner:
//   below_confidence -> policies.thresholds.confidence
//   after_attempts   -> policies.limits.max_slot_attempts
//   reprompt         -> the per-slot `reprompt` response key in the schema,
//                       which is a different mechanism that shares the word.
//
// When the escalation ladder is genuinely implemented, it comes back as a
// section with a consumer. Until then the pack does not claim to have one.

// MARK: - runtime/guards.json

/// Corrections applied to a classified intent BEFORE the dispatcher sees it.
/// Distinct from the confidence thresholds: those decide whether an intent fires
/// at all, whereas a guard fires regardless of confidence.
///
/// Additive section — a pack without it simply has no guards.
struct PackGuards: Decodable, Sendable {
    let helpMarker: HelpMarker?
    let polarity: [PolarityGuard]

    enum CodingKeys: String, CodingKey {
        case helpMarker = "help_marker"
        case polarity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        helpMarker = try c.decodeIfPresent(HelpMarker.self, forKey: .helpMarker)
        polarity = try c.decodeIfPresent([PolarityGuard].self, forKey: .polarity) ?? []
    }

    static let empty = PackGuards()
    private init() { helpMarker = nil; polarity = [] }

    /// Redirects a command to its help counterpart when the utterance is a
    /// question about it — "how do i turn up the volume" must show help, not
    /// change the volume.
    struct HelpMarker: Decodable, Sendable {
        let markers: String
        /// classified intent → help intent to substitute.
        let pairs: [String: String]
    }

    struct PolarityGuard: Decodable, Sendable {
        let intent: String
        let pattern: String
        /// Absent means suppress to the out-of-scope fallback.
        let redirect: String?
    }
}

// MARK: - keywords/<lang>.json

struct PackKeywords: Decodable, Sendable {
    let lang: String
    let rules: [Rule]

    /// Tier 1 is an exact anchored match (`^mute$`), tier 2 a looser pattern.
    /// The flattened root shim drops the tier and 9 of these rules entirely.
    struct Rule: Decodable, Sendable {
        let intent: String
        let pattern: String
        let tier: Int
        /// Patterns that VETO the match — the utterance looks like this intent
        /// but a guard word says otherwise.
        let guards: [String]

        enum CodingKeys: String, CodingKey { case intent, pattern, tier, guards }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            intent = try c.decode(String.self, forKey: .intent)
            pattern = try c.decode(String.self, forKey: .pattern)
            tier = try c.decodeIfPresent(Int.self, forKey: .tier) ?? 2
            guards = try c.decodeIfPresent([String].self, forKey: .guards) ?? []
        }
    }
}

// MARK: - entities/shared/content.json

struct PackEntities: Decodable, Sendable {
    let entities: [String: EntityDefinition]
}

/// Values are LANGUAGE-KEYED (`{"en": [...]}`). In a per-language pack that map
/// has exactly one key, but reading it by language rather than taking the first
/// value is what keeps the code honest if that ever changes.
struct EntityDefinition: Decodable, Sendable {
    let type: String
    let fuzzy: Bool
    /// The value list is a hint, not a closed set — a free-text answer is
    /// acceptable and the runtime may derive one from the utterance.
    ///
    /// Added to the format in response to VIK-017: the flag existed upstream and
    /// was dropped by the v3 projection, so `remind` looked closed and could not
    /// be filled from free text. `decodeIfPresent` because packs built before
    /// that fix do not carry it — absent means closed, which is the safe reading.
    let open: Bool
    let values: [String: [String: [String]]]
    /// `runtime.builtin.datetime`, `runtime.builtin.integer`, or the bare
    /// `runtime.builtin` from a pack built before VIK-019.
    let dynamicSource: String?

    enum CodingKeys: String, CodingKey {
        case type, fuzzy, open, values
        case dynamicSource = "dynamic_source"
    }

    init(from decoder: Decoder) throws {
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
    func synonyms(language: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (canonical, byLang) in values {
            if let syns = byLang[language] { out[canonical] = syns }
        }
        return out
    }

    var isDynamic: Bool { type == "dynamic" }
}

// MARK: - telemetry/schema.json

/// Enums only — the pack publishes the closed vocabularies, not the event
/// shape. Values are validated against these before emission so a client cannot
/// invent a stage or outcome name the backend will reject.
struct PackTelemetrySchema: Decodable, Sendable {
    let telemetrySchemaVersion: Int
    let enums: Enums

    enum CodingKeys: String, CodingKey {
        case telemetrySchemaVersion = "telemetry_schema_version"
        case enums
    }

    struct Enums: Decodable, Sendable {
        let lifecycle: [String]
        let outcome: [String]
        let routingReason: [String]
        let stages: [String]

        enum CodingKeys: String, CodingKey {
            case lifecycle, outcome, stages
            case routingReason = "routing_reason"
        }
    }
}
