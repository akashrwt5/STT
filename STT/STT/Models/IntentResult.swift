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

    /// Human-readable display label.
    public var displayLabel: String {
        switch self {
        case .intent(let label, _): return Self.humanize(label)
        case .genai: return "Unknown"
        }
    }

    /// SF Symbol name for this intent.
    public var systemImage: String {
        switch self {
        case .genai: return "questionmark.circle"
        case .intent(let label, _):
            switch label {
            case "REMINDER":        return "bell.badge"
            case "VOLUME_INCREASE": return "speaker.wave.3"
            case "VOLUME_DECREASE": return "speaker.wave.1"
            case "VOLUME_MUTE":     return "speaker.slash"
            case "VOLUME_UNMUTE":   return "speaker.wave.2"
            case "NOTIFICATIONS":   return "bell"
            case "MEMORY":          return "brain"
            case "PUSH_TO_TALK":    return "message"
            case "SELFCHECK":       return "checkmark.shield"
            case "TRANSLATE":       return "character.bubble"
            case "TRANSCRIBE":      return "waveform"
            case "TELEHEARAI":      return "ear"
            case "ACTIVITY":        return "figure.walk"
            case "BATTERY":         return "battery.75"
            case "FIND_MY_PHONE":   return "location"
            case "HELP":            return "questionmark.circle.fill"
            case "LISTEN_MESSAGE":  return "headphones"
            case "OUT_OF_SCOPE":    return "arrow.up.right.circle"
            default:                return "tag"
            }
        }
    }

    /// Converts uppercase snake_case label to human-readable title.
    private static func humanize(_ label: String) -> String {
        label.replacingOccurrences(of: "_", with: " ").capitalized
    }
}