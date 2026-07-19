// FMClassificationOutput.swift
// STT — FoundationModelNLU (evaluation sample; see docs/FM_SAMPLE_PLAN.md)
//
// The guided-generation response shape. Deliberately minimal: the FM sample
// reuses NLUEngine's deterministic slot extraction over the raw utterance
// (EntityExtractor + datetime grammar), so the model is asked ONLY for the
// intent decision plus a self-rating. Asking for less also keeps per-turn
// output tokens (and therefore latency) down.
//
// The self-rated confidence is DISPLAY-ONLY and explicitly uncalibrated —
// FoundationModels exposes no logprobs, so unlike the cascade's temperature-
// scaled scores this number has no empirical accuracy guarantee. It must
// never be used for threshold gating (see FMIntentClassifierService for how
// gating is handled instead).

import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct FMClassificationOutput: Sendable {
    @Guide(description: "The single intent that best matches the user's utterance. Use outOfScope when nothing fits.")
    var intent: FMIntent

    @Guide(description: "Your confidence in this classification from 0.0 to 1.0.")
    var confidence: Double
}
#endif
