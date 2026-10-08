// IntentResult.swift
// VoiceAIKit
//
// Types that describe one classification: `ClassificationBreakdown`,
// `ClassificationResult` and `IntentResult`.

import Foundation

/// Shows how the 3-stage classification pipeline reached its answer.
/// It is used for debugging.
struct ClassificationBreakdown: Sendable {
    struct StageResult: Sendable {
        /// 1 = keyword rule, 2 = TF-IDF/CoreML model, 3 = MiniLM semantic model.
        /// Stage 3 does not run currently.
        let stage: Int
        let intent: String
        let confidence: Double

        init(stage: Int, intent: String, confidence: Double) {
            self.stage = stage
            self.intent = intent
            self.confidence = confidence
        }
    }

    /// The stage that decided the result: 1, 2 or 3.
    /// `nil` when no stage was confident enough, or when the utterance had no words
    /// the model knows.
    let winningStage: Int?
    /// The Stage 2 (model) result. It is set even when a keyword rule wins.
    /// `nil` only when the utterance has no words the model knows.
    let stage2: StageResult?
    /// The Stage 3 (MiniLM) result. Currently always `nil`, because Stage 3 does not run.
    let stage3: StageResult?

    init(winningStage: Int?, stage2: StageResult?, stage3: StageResult?) {
        self.winningStage = winningStage
        self.stage2 = stage2
        self.stage3 = stage3
    }
}

/// What a classifier returns for one utterance.
struct ClassificationResult: Sendable {
    /// The label of the intent the classifier chose.
    let label: String
    /// Confidence from 0 to 1. Normally the model's probability. When a keyword rule
    /// decided the label against the model, it is a fixed value instead.
    let confidence: Double
    /// True when the semantic stage produced this result. Currently always false.
    let semanticRescue: Bool
    /// Per-stage detail, for debugging.
    let breakdown: ClassificationBreakdown
    /// How a keyword rule and the model compared on this turn. `nil` when no keyword
    /// rule fired. `NLUEngine` uses it to choose the confidence bar to clear:
    /// `policies.thresholds.agreement` when `corroborated`, the normal `confidence`
    /// threshold otherwise. `confidence` itself is not changed.
    let arbitration: Arbitration?

    /// The result of comparing a keyword rule with the model.
    enum Arbitration: String, Sendable {
        /// The rule and the model chose the same intent.
        case corroborated
        /// The model says the utterance is out of scope, but a rule matched. The rule's
        /// label is kept, with a low fixed confidence, so the turn ends in the fallback.
        /// This stops "who is the prime minister of create reminder" from firing
        /// "create reminder".
        case contested
        /// A rule matched and the model chose a different in-scope intent. The rule's
        /// label is used, and `confidence` is a fixed value, not a probability (see
        /// `PackClassifierAdapter.ruleOnlyConfidence`).
        case ruleOnly
    }

    /// `arbitration` defaults to `nil`, so a classifier without a keyword stage
    /// needs no change.
    init(label: String,
                confidence: Double,
                semanticRescue: Bool,
                breakdown: ClassificationBreakdown,
                arbitration: Arbitration? = nil) {
        self.label = label
        self.confidence = confidence
        self.semanticRescue = semanticRescue
        self.breakdown = breakdown
        self.arbitration = arbitration
    }
}

/// The outcome of classifying one transcription.
/// VoiceAIKit does not create it. A host app can use it to hold and show a result.
enum IntentResult: Sendable {
    /// A recognised intent, with its label and the model's confidence (0 to 1).
    /// `semanticRescue` is true when Stage 3 produced the result.
    case intent(label: String, confidence: Double, semanticRescue: Bool = false)
    /// Confidence was too low. Holds a URL for searching the query, and the confidence.
    case genai(url: URL, confidence: Double)
    /// The user changed topic during slot filling. Holds the name of the abandoned intent.
    case interrupted(cancelledIntent: String)

    var confidence: Double {
        switch self {
        case .intent(_, let c, _): return c
        case .genai(_, let c):     return c
        case .interrupted:         return 0
        }
    }

    /// Title to show in the UI, e.g. "Volume Increase".
    var displayLabel: String {
        switch self {
        case .intent(let label, _, _):          return Self.humanize(label)
        case .genai:                             return "Unknown"
        case .interrupted(let c):               return "Interrupted: \(Self.humanize(c)) flow cancelled"
        }
    }

    /// SF Symbol name for the intent, for the host app's UI.
    var systemImage: String {
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
            result.append(char)
            prev = char
        }
        return result
    }
}
