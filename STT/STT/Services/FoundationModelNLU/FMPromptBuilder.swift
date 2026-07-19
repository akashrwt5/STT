// FMPromptBuilder.swift
// STT — FoundationModelNLU (evaluation sample; see docs/FM_SAMPLE_PLAN.md)
//
// Builds the session instructions: the intent catalog plus few-shot anchors
// for the historically confusable pairs. The catalog is generated from
// FMIntentSchema so it can never drift from the enum (single source of truth).
//
// Token budget: 60 catalog lines ≈ 12–16 tokens each plus few-shots lands the
// instructions around 1.1–1.4K tokens — comfortable inside the 4,096-token
// session context with room for many turns. `estimatedTokenCount` asserts
// this at startup in DEBUG so a future catalog edit can't silently blow the
// budget (plan §10, risk 1).

import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
enum FMPromptBuilder {

    /// Session instructions covering role, catalog, disambiguation rules, and
    /// few-shot anchors. Built once per session, not per turn.
    static func instructions() -> String {
        var lines: [String] = []
        lines.append("""
        You classify a single user utterance from a hearing-aid companion app \
        into exactly one intent. Users control hearing aids by voice: volume, \
        hearing memories (sound presets), reminders, messages, streaming, \
        transcription, translation, activity and health stats, and product help.
        """)
        lines.append("")
        lines.append("Intents:")
        for intent in FMIntent.allCases {
            lines.append("- \(intent): \(intent.catalogDescription)")
        }
        lines.append("")
        lines.append("""
        Rules:
        1. Commands vs help: "turn up the volume" is a command (volumeUp); \
        "how does volume work" is a question (helpVolume). Apply this \
        command-vs-question test to every domain (battery, memories, \
        transcription, translation, reminders, health).
        2. Negation: if the user says they do NOT want something, do not pick \
        that action's intent ("I don't want to translate this" is NOT \
        startTranslation).
        3. Indirect phrasing counts: "it's too quiet in here" means volumeUp; \
        "everything is too loud" means volumeDown.
        4. outOfScope is for anything the app cannot do: weather, news, \
        general knowledge, jokes, controlling other apps, open conversation.
        5. Choose exactly one intent. When torn between a specific intent and \
        outOfScope, prefer the specific intent only if the utterance clearly \
        concerns hearing aids, the app, reminders, messages, or health stats.
        """)
        lines.append("")
        lines.append("""
        Examples:
        "check my heart rate stats" → healthSummary
        "how does heart rate tracking work" → helpHeartRate
        "what is heart rate recovery" → helpHeartRateRecovery
        "mute my hearing aids" → volumeMute
        "turn the sound down a bit" → volumeDown
        "how many steps today" → activitySteps
        "remind me to call the doctor tomorrow" → addReminder
        "how do reminders work" → helpReminder
        "what's the weather like" → outOfScope
        "who is the president of India" → outOfScope
        """)
        return lines.joined(separator: "\n")
    }

    /// Crude token estimate (~4 chars/token heuristic) for the DEBUG budget
    /// assertion. Precision is not the point — catching a 3x catalog blowup is.
    static var estimatedTokenCount: Int {
        instructions().count / 4
    }

    /// Upper bound the instructions must stay under to leave conversational
    /// headroom in the 4,096-token session context.
    static let instructionTokenBudget = 2_000
}
#endif
