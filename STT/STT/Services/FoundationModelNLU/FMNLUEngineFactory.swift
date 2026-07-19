// FMNLUEngineFactory.swift
// STT — FoundationModelNLU (evaluation sample; see docs/FM_SAMPLE_PLAN.md)
//
// The factory seam that gives the FM sample the ENTIRE existing pipeline for
// free: LiveTranscriptionViewModel accepts any NLUEngineFactory, and NLUEngine
// accepts any IntentClassifying. Swapping the classifier here inherits speech,
// VAD endpointing, Stage-0 keyword triggers, slot filling, confirmation,
// context, TTS, and the conversation UI — all untouched (plan §3).
//
// Deliberately NOT added to NLUVariant / NLUEngineFactoryProvider: those are
// existing files, and the plan's ground rule is that the only existing-file
// edit is the additive landing-screen case. FMVoiceViewModel constructs this
// factory directly instead.

import Foundation
#if canImport(FoundationModels)

@available(iOS 26.0, *)
public struct FMNLUEngineFactory: NLUEngineFactory {
    public init() {}

    public func makeEngine() -> any ConversationEngine {
        NLUEngine(classifier: FMIntentClassifierService())
    }
}
#endif
