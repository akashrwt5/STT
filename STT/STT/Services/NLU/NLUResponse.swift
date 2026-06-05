// NLUResponse.swift
// STT
//
// The outcome of a single NLU turn. Replaces the Python NLUResult dataclass
// with strongly-typed Swift cases the UI can switch over directly.

import Foundation

public enum NLUResponse: Sendable {
    /// A required slot is missing — ask `question` and keep listening.
    /// `intent` and `filled` carry the in-progress state for display.
    case prompt(intent: String, question: String, filled: [String: String])

    /// A yes/no confirmation is needed (e.g. "Do you want to send this message?").
    case confirm(intent: String, action: String?, question: String)

    /// All slots collected (or none needed) — ready to execute `action`.
    case fulfill(intent: String, action: String?, parameters: [String: String], message: String, confidence: Double)

    /// Low confidence or out-of-scope — hand off to the GenAI fallback URL.
    case fallback(url: URL, confidence: Double)

    /// The prompt/question the UI should surface this turn, if any.
    public var pendingQuestion: String? {
        switch self {
        case .prompt(_, let q, _):   return q
        case .confirm(_, _, let q):  return q
        case .fulfill, .fallback:    return nil
        }
    }

    /// True when this turn finished a conversation (fulfilled or fell back).
    public var isTerminal: Bool {
        switch self {
        case .fulfill, .fallback: return true
        case .prompt, .confirm:   return false
        }
    }
}
