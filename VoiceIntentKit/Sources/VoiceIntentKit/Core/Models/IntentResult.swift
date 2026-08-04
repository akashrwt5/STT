// IntentResult.swift
// STT

import Foundation

/// Per-stage debug breakdown produced by the 3-stage classification pipeline.
/// Attached to cards so the eye button can show exactly which stage answered and why.
public struct ClassificationBreakdown: Sendable {
    public struct StageResult: Sendable {
        /// 1 = keyword rule, 2 = TF-IDF CoreML, 3 = MiniLM semantic
        public let stage: Int
        public let intent: String
        public let confidence: Double

        // Written in the type body, NOT an extension. A memberwise initialiser
        // added in an extension does not suppress the synthesised one — it
        // collides with it. In the body it replaces it, which is also what makes
        // it `public`: the synthesised memberwise init of a public struct is
        // internal, so a consumer outside the module could never build one.
        public init(stage: Int, intent: String, confidence: Double) {
            self.stage = stage
            self.intent = intent
            self.confidence = confidence
        }
    }

    /// Stage that produced the winning answer (1–3).
    /// `nil` when no stage met the confidence threshold → GENAI fallback.
    public let winningStage: Int?
    /// Stage 2 (TF-IDF) result. `nil` only for pure keyword (stage 1) hits.
    public let stage2: StageResult?
    /// Stage 3 (MiniLM) result. `nil` if Stage 3 not loaded or not triggered.
    public let stage3: StageResult?

    public init(winningStage: Int?, stage2: StageResult?, stage3: StageResult?) {
        self.winningStage = winningStage
        self.stage2 = stage2
        self.stage3 = stage3
    }
}

/// What a classifier returns for one utterance.
///
/// Moved here from `IntentClassifierService`, which was deleted with the rest of
/// the bundle-loading stack. It belongs next to `ClassificationBreakdown`: both
/// are the shape of a classification, not the implementation of one, and
/// `IntentClassifying` — the protocol every classifier satisfies — is written in
/// terms of them.
public struct ClassificationResult: Sendable {
    public let label: String
    public let confidence: Double
    /// True when the semantic stage produced this result.
    ///
    /// Always false under a pack that disables the semantic stage, which
    /// `pack-en` does — its report card was measured that way.
    public let semanticRescue: Bool
    /// Per-stage detail, for the debug panel.
    public let breakdown: ClassificationBreakdown

    public init(label: String,
                confidence: Double,
                semanticRescue: Bool,
                breakdown: ClassificationBreakdown) {
        self.label = label
        self.confidence = confidence
        self.semanticRescue = semanticRescue
        self.breakdown = breakdown
    }
}

/// The outcome of running intent classification on a transcription result.
public enum IntentResult: Sendable {
    /// A recognised intent with its label and model confidence (0–1).
    /// `semanticRescue` is true when Stage 3 (MiniLM) produced this result.
    case intent(label: String, confidence: Double, semanticRescue: Bool = false)
    /// Confidence below threshold — includes a GenAI fallback URL for the query.
    case genai(url: URL, confidence: Double)
    /// User switched topics mid slot-filling — shows the abandoned intent name.
    case interrupted(cancelledIntent: String)

    public var confidence: Double {
        switch self {
        case .intent(_, let c, _): return c
        case .genai(_, let c):     return c
        case .interrupted:         return 0
        }
    }

    /// Human-readable display label.
    public var displayLabel: String {
        switch self {
        case .intent(let label, _, _):          return Self.humanize(label)
        case .genai:                             return "Unknown"
        case .interrupted(let c):               return "Interrupted: \(Self.humanize(c)) flow cancelled"
        }
    }

    /// SF Symbol name for this intent.
    public var systemImage: String {
        switch self {
        case .genai:                  return "questionmark.circle"
        case .interrupted:            return "xmark.circle"
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
