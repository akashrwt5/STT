// IntentResult.swift
// STT

import Foundation

/// The outcome of running intent classification on a transcription result.
public enum IntentResult: Sendable {
    /// A recognised intent with its label and model confidence (0–1).
    case intent(label: String, confidence: Double)
    /// Confidence below threshold — includes a GenAI fallback URL for the query.
    case genai(url: URL, confidence: Double)

    public var confidence: Double {
        switch self {
        case .intent(_, let c): return c
        case .genai(_, let c): return c
        }
    }

    /// Human-readable label, e.g. "Reminder", "Volume", or "Unknown".
    public var displayLabel: String {
        switch self {
        case .intent(let label, _): return label
        case .genai: return "Unknown"
        }
    }

    /// SF Symbol name that represents this intent.
    public var systemImage: String {
        switch self {
        case .genai: return "questionmark.circle"
        case .intent(let label, _):
            switch label {
            case "Reminder":     return "bell.badge"
            case "Volume":       return "speaker.wave.2"
            case "Notifications": return "bell"
            case "Memory":       return "brain"
            case "Push To Talk": return "message"
            case "SelfCheck":    return "checkmark.shield"
            case "Translate":    return "character.bubble"
            case "Transcribe":   return "waveform"
            case "TeleHearAI":   return "ear"
            default:             return "tag"
            }
        }
    }
}