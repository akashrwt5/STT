// GenerativeIntentClassifying.swift
// VoiceAIKit
//
// The contract for a generative intent model (Apple's on-device language model
// today), and the settings that decide whether and how it runs.
//
// Kept free of `FoundationModels` so the cascade and its tests build and run
// without that framework.

import Foundation

// MARK: - Verdict

/// One answer from a generative intent model.
struct GenerativeVerdict: Sendable, Equatable {
    /// One of the pack's intent labels, the fallback label included.
    let intent: String
    /// The model's own rating of its answer, from 0 to 1.
    ///
    /// NOT a calibrated probability. Unlike the pack classifier's confidence,
    /// nothing measured how often an answer rated 0.8 is right. It is compared
    /// against the same fire bar only because the engine has one bar.
    let confidence: Double
    /// Time the model took to answer.
    let latency: Duration

    /// The intent to report: the fallback label when the model says the
    /// utterance is not for the app, otherwise the label it chose.
    static func resolvedIntent(inScope: Bool, label: String, outOfScopeIntent: String) -> String {
        inScope ? label : outOfScopeIntent
    }
}

// MARK: - Contract

/// A model that maps an utterance to one of a fixed set of intent labels.
protocol GenerativeIntentClassifying: Actor {
    /// Classifies `text`. Nil when the model is unavailable on this device,
    /// refuses the input, or fails; the caller then keeps its own answer.
    func classify(_ text: String) async -> GenerativeVerdict?
    /// Loads the model into memory ahead of the first turn. Safe to call repeatedly.
    func prewarm() async
}

// MARK: - Settings

/// Everything the cascade needs to know about the language model stage.
struct FoundationModelSettings: Sendable, Equatable {
    /// Never `.packOnly`: that mode has no settings, `resolve` returns nil.
    let mode: IntentClassifierMode
    let instructions: String?
    let intentDescriptions: [String: String]
    /// Log the model's input and output. Only a development override sets it;
    /// a pack cannot.
    var logsModelIO = false

    /// Settings for this pack, or nil when the mode is `.packOnly`.
    static func resolve(pack: ResolvedPack,
                        override: FoundationModelOverride?) -> FoundationModelSettings? {
        resolve(packMode: pack.classifierMode, packLLM: pack.llm, override: override)
    }

    /// The text always comes from the pack's `llm/<language>.json` unless a
    /// development override supplies its own. A development override always
    /// decides the mode, so `.packOnly` turns the stage off even when the pack
    /// turns it on, and any other mode turns it on with the pack's text.
    static func resolve(packMode: IntentClassifierMode,
                        packLLM: PackLLM?,
                        override: FoundationModelOverride?) -> FoundationModelSettings? {
        let mode = override?.mode ?? packMode
        guard mode != .packOnly else { return nil }
        let overrideDescriptions = override?.intentDescriptions ?? [:]
        return FoundationModelSettings(
            mode: mode,
            instructions: override?.instructions ?? packLLM?.instructions,
            intentDescriptions: overrideDescriptions.isEmpty
                ? (packLLM?.intentDescriptions ?? [:])
                : overrideDescriptions,
            logsModelIO: override?.logsModelIO ?? false)
    }

    /// The instructions sent to the model: the locale line (see `localeLine`),
    /// the base instructions, then one `label: description` line per described
    /// label, in label order.
    ///
    /// Apart from the locale line, only punctuation is added here, never words,
    /// so the text stays in the language the pack wrote it in. Nil when there is
    /// nothing to send.
    func composedInstructions(labels: [String], locale: Locale? = nil) -> String? {
        var parts: [String] = []
        if let locale, let line = Self.localeLine(for: locale) { parts.append(line) }
        if let instructions, !instructions.isEmpty { parts.append(instructions) }
        for label in labels {
            guard let description = intentDescriptions[label], !description.isEmpty else { continue }
            parts.append("\(label): \(description)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Apple's locale phrase, or nil for U.S. English.
    ///
    /// This one sentence is the exception to "the package adds no words": it is
    /// not text for the user but a fixed phrase from the model's training, which
    /// Apple asks for in exactly this English form, at the start of the
    /// instructions, for every locale other than U.S. English ("Supporting
    /// languages and locales with Foundation Models"). It is the same sentence
    /// whatever language the pack is in.
    static func localeLine(for locale: Locale) -> String? {
        if Locale.Language(identifier: "en_US").isEquivalent(to: locale.language) { return nil }
        return "The person's locale is \(locale.identifier(.icu))."
    }
}
