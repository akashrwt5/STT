// NLUEngineFactoryProvider.swift
// VoiceIntentKit
//
// One factory function: given a language code, return a fully configured
// `ConversationEngine`. All variant selection is data-driven via the pack's
// manifest (`LanguagePackRegistry`) — this file no longer enumerates
// architectural pathways.
//
// Adding a language is a new `Resources/LanguagePacks/<code>/manifest.json`
// plus its overlay files. Zero Swift edits.

import Foundation
import os.log

public enum NLUEngineFactoryProvider {

    private static let log = Logger(subsystem: "com.voiceintentkit", category: "NLUEngineFactoryProvider")

    /// Build a `ConversationEngine` for `language`. When no pack is registered
    /// for the code, falls back to the English pack so misconfigured callers
    /// still get something usable.
    ///
    /// If even the English pack is missing, the bundle itself is broken — we
    /// `fatalError` because there is no meaningful engine to hand back and
    /// silently degrading would mask a shipping-configuration bug.
    public static func makeEngine(language: String) -> any ConversationEngine {
        if let pack = LanguagePackRegistry.pack(for: language) {
            return buildEngine(from: pack)
        }
        log.error("No language pack for '\(language, privacy: .public)' — falling back to English pack")
        guard let english = LanguagePackRegistry.pack(for: "en") else {
            fatalError("VoiceIntentKit: English language pack missing from bundle. Verify Resources/LanguagePacks/en/manifest.json is present.")
        }
        return buildEngine(from: english)
    }

    // MARK: - Construction

    private static func buildEngine(from pack: LanguagePack) -> any ConversationEngine {
        let classifier = IntentClassifierService(
            bundle: LanguagePackRegistry.classifierBundle(for: pack),
            confThreshold: pack.classifier.confThreshold,
            confGapThreshold: pack.classifier.confGapThreshold
        )

        // Packs that ride on the shared multilingual model ship a schema
        // overlay + per-language entities + lexicon. Packs whose schema is the
        // canonical source (English) don't — the engine's static defaults are
        // the canonical schema, so no wiring is required.
        guard pack.schemaOverlay != nil else {
            return NLUEngine(classifier: classifier)
        }

        let lex = LocalizationLoader.lexicon(language: pack.language)
        return NLUEngine(
            schema: LocalizationLoader.schema(language: pack.language),
            classifier: classifier,
            entities: EntityExtractor(entitiesURL: LocalizationLoader.entitiesURL(language: pack.language),
                                      lexicon: lex),
            uncertain: lex?.uncertain.isEmpty == false ? lex!.uncertain : NLUEngine.defaultUncertain,
            noIdioms:  lex?.noIdioms.isEmpty  == false ? lex!.noIdioms  : NLUEngine.defaultNoIdioms,
            carriers:  lex?.carrierPhrases.isEmpty == false ? lex!.carrierPhrases : NLUEngine.defaultCarriers
        )
    }
}
