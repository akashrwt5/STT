// ConfirmationGate.swift
// VoiceAIKit
//
// When an intent asks "shall I?" before acting.
//
// The pack answers this in two separate tables, and both were being ignored
// (VIK-021). `runtime/policies.json → confirmation` says WHICH intents are
// gated; `policies.thresholds.uncertain_confirm_below` / `_floor` say WHEN.
// `PackEngineFactory` used to build a confirmation for any intent whose
// workflow carried a `confirmation` block, which is neither table — the block
// only says what the question WOULD be.
//
// For `pack-en-v1.0.29` those tables read: 43 intents `never`, 14
// `when_ambiguous`, 0 `always`. So the shipped behaviour was "confirm all 14
// unconditionally", and two of those 14 have slots, which is where it stopped
// being merely annoying — see `NLUEngine.handleConfirmation`.

import Foundation

/// Whether an intent confirms, and on what evidence.
enum ConfirmationGate: Sendable, Equatable {

    /// Always ask. Also the default for an intent with no gate configured, which
    /// is what preserves the pre-pack behaviour: the old `nlu_schema.json`
    /// expressed "confirm" purely by the presence of a `followup`, with no
    /// policy table to consult.
    case always

    /// Never ask, regardless of confidence.
    case never

    /// Ask only when the classifier is unsure — confidence in `[floor, ceiling)`.
    ///
    /// Above `ceiling` the model is sure enough to act; below `floor` it is too
    /// unsure to be worth confirming, and the engine's own confidence threshold
    /// has already routed that turn to fallback. So in practice the effective
    /// band is `[max(floor, confidenceThreshold), ceiling)` — 0.70…0.91 for
    /// `pack-en`, not 0.55…0.91. The floor is kept as the pack states it rather
    /// than pre-multiplied, because the two thresholds move independently.
    case whenAmbiguous(floor: Double, ceiling: Double)

    /// Half-open on purpose: `uncertain_confirm_below` is named "below", so a
    /// confidence exactly at the ceiling is NOT ambiguous.
    func fires(confidence: Double) -> Bool {
        switch self {
        case .always:
            return true
        case .never:
            return false
        case .whenAmbiguous(let floor, let ceiling):
            return confidence >= floor && confidence < ceiling
        }
    }
}
