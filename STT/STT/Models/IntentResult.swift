// IntentResult.swift
// STT

import Foundation

/// The outcome of running intent classification on a transcription result.
public enum IntentResult: Sendable {
    /// A recognised intent with its label and model confidence (0–1).
    /// `semanticRescue` is true when Stage 3 (MiniLM) produced this result.
    case intent(label: String, confidence: Double, semanticRescue: Bool = false)
    /// Confidence below threshold — includes a GenAI fallback URL for the query.
    case genai(url: URL, confidence: Double)

    public var confidence: Double {
        switch self {
        case .intent(_, let c, _): return c
        case .genai(_, let c): return c
        }
    }

    /// Human-readable display label.
    public var displayLabel: String {
        switch self {
        case .intent(let label, _, _): return Self.humanize(label)
        case .genai: return "Unknown"
        }
    }

    /// SF Symbol name for this intent.
    public var systemImage: String {
        switch self {
        case .genai: return "questionmark.circle"
        case .intent(let label, _, _):
            switch true {
            case label == "Default Fallback Intent":        return "questionmark.circle"
            case label == "reminders.add":                  return "bell.badge"
            case label == "reminders.complete":             return "checkmark.circle"
            // Volume
            case label == "Cmd.VolumeIncrease",
                 label == "Cmd.VolumeUnmute":               return "speaker.wave.3"
            case label == "Cmd.VolumeDecrease":             return "speaker.wave.1"
            case label == "Cmd.VolumeMute":                 return "speaker.slash"
            // Activity
            case label == "Cmd.ActivityRun":                return "figure.run"
            case label == "Cmd.ActivityCycle":              return "figure.outdoor.cycle"
            case label == "Cmd.ActivityCalories":           return "flame"
            case label.hasPrefix("Cmd.Activity"):           return "figure.walk"
            // Device / health
            case label == "Cmd.BatteryLevel":               return "battery.75"
            case label == "Cmd.FindMyPhone":                return "location"
            case label == "Cmd.Health":                     return "heart"
            case label == "Cmd.MemoryChange":               return "brain"
            // Messages
            case label == "Cmd.ListenMessage":              return "headphones"
            case label.hasPrefix("Cmd.SendMessage"):        return "message"
            // Media
            case label == "Cmd.StreamingStart":             return "play.circle"
            case label == "Cmd.StreamingStop":              return "stop.circle"
            // Transcribe / translate
            case label == "Cmd.TranscribeStart":            return "waveform"
            case label == "Cmd.TranslationStart":           return "character.bubble"
            // Help — specific
            case label == "Help_Battery":                   return "battery.75"
            case label == "Help_ChangingMemories",
                 label == "Help_MemoryOptions":             return "brain"
            case label == "Help_Reminder":                  return "bell.badge"
            case label == "Help_SelfCheck":                 return "checkmark.shield"
            case label == "Help_Transcribe":                return "waveform"
            case label == "Help_Translate":                 return "character.bubble"
            case label == "Help_Volume":                    return "speaker.wave.2"
            case label == "Help_Pairing":                   return "link"
            case label == "Help_Health",
                 label == "Help_HeartRate":                 return "heart.text.square"
            case label == "Help_HeartRateRecovery":         return "arrow.clockwise.heart"
            case label == "Help_FallAlert":                 return "figure.fall"
            case label == "Help_FindMyHearingAids":         return "location"
            case label == "Help_Tinnitus":                  return "ear.trianglebadge.exclamationmark"
            case label == "Help_InsertDevice":              return "ear"
            case label == "Help_IntelliVoice":              return "mic.fill"
            case label == "Help_MaskMode":                  return "facemask"
            case label == "Help_Pairing":                   return "link"
            case label == "Help_AppSettings",
                 label == "Help_DeviceSettings":            return "gearshape"
            case label == "Help_Home":                      return "house"
            case label == "Help_HearShare":                 return "shareplay"
            case label == "Help_HearingCareAnywhereConnect": return "wifi"
            case label == "Help_RemoteProgramming":         return "dot.radiowaves.left.and.right"
            case label == "Help_ThriveScore":               return "chart.bar"
            case label == "Help_WhatsNew":                  return "sparkles"
            case label == "Help_WiCROS":                    return "headphones"
            case label.hasPrefix("Help_"):                  return "questionmark.circle.fill"
            default:                                        return "tag"
            }
        }
    }

    /// Converts a Dialogflow-style intent label to a human-readable title.
    /// Examples: "Cmd.VolumeIncrease" → "Volume Increase",
    ///           "Help_Pairing" → "Pairing", "reminders.add" → "Add Reminder"
    private static func humanize(_ label: String) -> String {
        if label.hasPrefix("Cmd.") {
            let name = String(label.dropFirst(4))
            return insertSpaces(before: name)
        }
        if label.hasPrefix("Help_") {
            return insertSpaces(before: String(label.dropFirst(5)))
        }
        if label.hasPrefix("reminders.") {
            let action = String(label.dropFirst("reminders.".count)).capitalized
            return "\(action) Reminder"
        }
        return label
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .capitalized
    }

    /// Inserts a space before each uppercase letter that follows a lowercase one,
    /// turning camelCase into "Camel Case".
    private static func insertSpaces(before camel: String) -> String {
        var result = ""
        var prev: Character = " "
        for char in camel {
            if char.isUppercase && prev.isLowercase {
                result.append(" ")
            }
            // Handle separator like " - " in "SendMessage - no"
            result.append(char)
            prev = char
        }
        return result
    }
}
