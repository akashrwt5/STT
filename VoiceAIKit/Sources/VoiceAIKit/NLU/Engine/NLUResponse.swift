// NLUResponse.swift
// STT
//
// The outcome of a single NLU turn. Replaces the Python NLUResult dataclass
// with strongly-typed Swift cases the UI can switch over directly.

import Foundation

indirect enum NLUResponse: Sendable {
    /// A required slot is missing — ask `question` and keep listening.
    /// `intent` and `filled` carry the in-progress state for display.
    case prompt(intent: String, question: String, filled: [String: String])

    /// A yes/no confirmation is needed (e.g. "Do you want to send this message?").
    case confirm(intent: String, action: String?, question: String, filled: [String: String])

    /// All slots collected (or none needed) — ready to execute `action`.
    /// `semanticRescue` is true when Stage 3 (MiniLM) classified this intent.
    case fulfill(intent: String, action: String?, parameters: [String: String], message: String, confidence: Double, semanticRescue: Bool = false, breakdown: ClassificationBreakdown? = nil)

    /// Low confidence or out-of-scope. `intent` is the pack's fallback intent
    /// name — `Default Fallback Intent` — so the host dispatches this like any
    /// other intent instead of special-casing a separate shape.
    ///
    /// It used to carry `url:`, a GenAI hand-off address built from a field in
    /// the pack with the user's verbatim transcript in its query string. Nothing
    /// ever opened it, and an unsigned pack could choose where it pointed. Where
    /// an unrecognised utterance goes next is the host's decision (VIK-031).
    case fallback(intent: String, confidence: Double, breakdown: ClassificationBreakdown? = nil)

    /// The user switched topics mid slot-filling. `cancelledIntent` is the
    /// abandoned flow; `result` is the outcome for the new intent (mirrors
    /// Python NLUResult.interrupted_intent).
    case interrupted(cancelledIntent: String, result: NLUResponse)

    /// The prompt/question the UI should surface this turn, if any.
    var pendingQuestion: String? {
        switch self {
        case .prompt(_, let q, _):   return q
        case .confirm(_, _, let q, _):  return q
        case .interrupted(_, let r): return r.pendingQuestion
        case .fulfill, .fallback:    return nil
        }
    }

    /// True when this turn finished a conversation (fulfilled or fell back).
    var isTerminal: Bool {
        switch self {
        case .fulfill, .fallback:    return true
        case .interrupted(_, let r): return r.isTerminal
        case .prompt, .confirm:      return false
        }
    }
}
