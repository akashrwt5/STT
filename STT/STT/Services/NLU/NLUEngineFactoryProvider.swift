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
        // TODO(multilingual-schema): the engine still loads the English
        // nlu_schema.json / nlu_entities.json by default, so slot prompts and
        // entity extraction remain English. A future iteration injects a
        // locale-appropriate schema URL through this factory (see
        // MultilingualIntentClassifierService and docs §4).
        NLUEngine(classifier: MultilingualIntentClassifierService())
    }
}
