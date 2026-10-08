// ConfirmationGate.swift
// VoiceAIKit
//
// Decides whether an intent asks "shall I?" before it runs.

import Foundation

/// Tells whether an intent asks for confirmation before it runs.
///
/// The pack has two tables for this. `policies.confirmation` says which intents ask.
/// `policies.thresholds.uncertain_confirm_below` and `uncertain_confirm_floor` say
/// when they ask. `PackEngineFactory.confirmationGates(from:)` builds one gate for
/// each intent from them.
enum ConfirmationGate: Sendable, Equatable {

    /// Always ask. `NLUEngine` also uses this for an intent that has no gate.
    case always

    /// Never ask, whatever the confidence.
    case never

    /// Ask only when the classifier is unsure: the confidence is at least `floor` and
    /// below `ceiling`.
    ///
    /// At `ceiling` or above, the model is sure enough to act. Below `floor`, the
    /// confidence is too low to ask. The engine's fire bar (`fireBar` in `NLUEngine`)
    /// sends most of those turns to the fallback before the gate is checked. So the real
    /// band starts at the larger of `floor` and that bar.
    case whenAmbiguous(floor: Double, ceiling: Double)

    /// Whether the intent asks at this confidence. For `.whenAmbiguous`, `ceiling` itself
    /// is not included, because `uncertain_confirm_below` means "below".
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
