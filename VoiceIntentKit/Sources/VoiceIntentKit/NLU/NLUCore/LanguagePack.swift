// LanguagePack.swift
// VoiceIntentKit
//
// One language's on-device pack, described by a JSON manifest at
// `Resources/LanguagePacks/<code>/manifest.json`. Adding a language is a new
// manifest file plus the resources it references — no Swift edits.
//
// The manifest is entirely data. `ClassifierSpec` names the model, weights,
// and calibration files so a dedicated new-language model is just "drop the
// files and describe them here" — the runtime IntentClassifier is unchanged.

import Foundation

public struct LanguagePack: Sendable, Decodable {

    /// NLU language tag ("en", "fr", "de", "da"). Also the pack directory name.
    public let language: String

    /// Human-readable name for pickers ("English", "Français").
    public let displayName: String

    /// BCP-47 identifier the speech recognizer uses ("en-US", "fr-FR").
    public let locale: String

    /// Classifier resources this pack loads. See `ClassifierSpec`.
    public let classifier: ClassifierSpec

    /// Canonical schema resource base name (no extension). Set for packs that
    /// own their schema; mutually exclusive with `schemaOverlay`.
    public let schema: String?

    /// Overlay resource base name (no extension) — merged over the canonical
    /// `nlu_schema` when the pack rides on a shared multilingual model.
    public let schemaOverlay: String?

    /// Entities JSON resource base name (no extension).
    public let entities: String

    /// Optional lexicon resource base name (no extension). Nil ⇒ NLUEngine
    /// static defaults are used.
    public let lexicon: String?
}

/// Classifier descriptor — what would previously have been a `ClassifierBundle`
/// static constant, now shipped in the manifest so a new dedicated model is a
/// pure data change.
public struct ClassifierSpec: Sendable, Decodable {

    /// Whether the pack ships its own model (`dedicated`) or rides on a
    /// shared multilingual one (`shared`). The distinction is documentary at
    /// runtime — the classifier loads whatever `model` names either way — but
    /// it makes intent clear in the manifest and enables future divergence.
    public enum Kind: String, Sendable, Decodable {
        case dedicated
        case shared
    }

    public let kind: Kind

    /// Base name (no extension) of the CoreML model in Bundle.module.
    public let model: String

    /// Base name (no extension) of the pure-Swift weights JSON.
    public let weights: String

    /// Per-language decision threshold: predicted confidence must exceed this
    /// to return an intent, otherwise the classifier falls back to GenAI.
    /// Nil ⇒ use the value baked into the weights JSON.
    public let confThreshold: Double?

    /// Per-language runner-up gap threshold: `confidence - runnerUp` must
    /// exceed this to accept the predicted intent. Nil ⇒ use the value baked
    /// into the weights JSON.
    public let confGapThreshold: Double?

    /// os.log category. Distinct per bundle so Console.app can filter.
    public let loggerCategory: String
}
