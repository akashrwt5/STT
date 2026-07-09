// NLUEngineFactoryProvider.swift
// STT
//
// The single point in the codebase that names concrete classifier types. The
// ViewModel and NLUEngine depend only on protocols; this file maps a runtime
// NLUVariant to a concrete pipeline. Adding a third variant is one new case here
// plus one new factory struct — zero edits to NLUEngine, the ViewModels, or the
// View.

import Foundation

// MARK: - Provider

/// Maps an `NLUVariant` to the appropriate `NLUEngineFactory`.
public enum NLUEngineFactoryProvider {
    public static func make(for variant: NLUVariant) -> any NLUEngineFactory {
        switch variant {
        case .english:      return EnglishNLUEngineFactory()
        case .multilingual: return MultilingualNLUEngineFactory()
        }
    }
}

// MARK: - English

public struct EnglishNLUEngineFactory: NLUEngineFactory {
    public init() {}

    public func makeEngine() -> any ConversationEngine {
        NLUEngine(classifier: IntentClassifierService())
    }
}

// MARK: - Multilingual

public struct MultilingualNLUEngineFactory: NLUEngineFactory {
    public init() {}

    public func makeEngine() -> any ConversationEngine {
        NLUEngine(classifier: MultilingualIntentClassifierService())
    }

    public func makeEngine(language: String) -> any ConversationEngine {
        let lex = LocalizationLoader.lexicon(language: language)
        return NLUEngine(
            schema: LocalizationLoader.schema(language: language),
            classifier: MultilingualIntentClassifierService(language: language),
            entities: EntityExtractor(entitiesURL: LocalizationLoader.entitiesURL(language: language),
                                      lexicon: lex),
            uncertain: lex?.uncertain.isEmpty == false ? lex!.uncertain : NLUEngine.defaultUncertain,
            noIdioms:  lex?.noIdioms.isEmpty  == false ? lex!.noIdioms  : NLUEngine.defaultNoIdioms,
            carriers:  lex?.carrierPhrases.isEmpty == false ? lex!.carrierPhrases : NLUEngine.defaultCarriers
        )
    }
}
