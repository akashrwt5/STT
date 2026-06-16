// KeywordMatcher.swift
// STT
//
// Stage 1 of the 3-stage intent classification pipeline.
// Mirrors _compile_keyword_rules() and _is_negated() in
// IntentClassifier/scripts/nlu/classifier.py.
//
// Calibrated confidence matches Python:
//   exact    = 0.97  (full-string equality)
//   contains = 0.85  (substring match, negation-checked)
//
// Negation window: 30 chars before the match position are scanned for
// negation cues. "Don't translate this" must NOT fire Cmd.TranslationStart.
// Exact matches are immune to negation (the user literally said just that word).

import Foundation

final class KeywordMatcher {

    // MARK: - Rule type

    enum MatchType { case exact, contains }

    struct Rule {
        let keyword: String
        let intent: String
        let matchType: MatchType
        var confidence: Double { matchType == .exact ? 0.97 : 0.85 }
    }

    // MARK: - State

    private let rules: [Rule]
    private static let negationCues = ["not ", "don't", "dont", "never ", "without ", "no "]

    // MARK: - Init

    init() { rules = Self.buildRules() }

    // MARK: - Public API

    /// Returns the first matching (intent, confidence), or nil.
    /// Rules are evaluated in declaration order — place more specific rules first.
    func match(_ text: String) -> (label: String, confidence: Double)? {
        let lower = text.lowercased()
        for rule in rules {
            switch rule.matchType {
            case .exact:
                if lower == rule.keyword {
                    return (rule.intent, rule.confidence)
                }
            case .contains:
                if let range = lower.range(of: rule.keyword) {
                    guard !isNegated(at: range.lowerBound, in: lower) else { continue }
                    return (rule.intent, rule.confidence)
                }
            }
        }
        return nil
    }

    // MARK: - Negation detection

    private func isNegated(at position: String.Index, in text: String) -> Bool {
        let distance = text.distance(from: text.startIndex, to: position)
        let windowStart = text.index(position, offsetBy: -min(30, distance))
        let window = text[windowStart..<position]
        return Self.negationCues.contains { window.contains($0) }
    }

    // MARK: - Rule definitions

    private static func buildRules() -> [Rule] {
        typealias R = Rule
        return [
            // Reminders — more specific first
            R(keyword: "don't let me forget",   intent: "reminders.add",      matchType: .contains),
            R(keyword: "dont let me forget",    intent: "reminders.add",      matchType: .contains),
            R(keyword: "create a reminder",     intent: "reminders.add",      matchType: .contains),
            R(keyword: "set a reminder",        intent: "reminders.add",      matchType: .contains),
            R(keyword: "set reminder",          intent: "reminders.add",      matchType: .contains),
            R(keyword: "add a reminder",        intent: "reminders.add",      matchType: .contains),
            R(keyword: "remind me",             intent: "reminders.add",      matchType: .contains),
            R(keyword: "reminder complete",     intent: "reminders.complete", matchType: .contains),
            R(keyword: "mark reminder done",    intent: "reminders.complete", matchType: .contains),
            R(keyword: "complete reminder",     intent: "reminders.complete", matchType: .contains),

            // Volume — "unmute" before "mute" to prevent substring collision
            R(keyword: "unmute",                intent: "Cmd.VolumeUnmute",   matchType: .contains),
            R(keyword: "increase volume",       intent: "Cmd.VolumeIncrease", matchType: .contains),
            R(keyword: "turn up the volume",    intent: "Cmd.VolumeIncrease", matchType: .contains),
            R(keyword: "volume up",             intent: "Cmd.VolumeIncrease", matchType: .contains),
            R(keyword: "turn it up",            intent: "Cmd.VolumeIncrease", matchType: .contains),
            R(keyword: "louder",                intent: "Cmd.VolumeIncrease", matchType: .contains),
            R(keyword: "decrease volume",       intent: "Cmd.VolumeDecrease", matchType: .contains),
            R(keyword: "turn down the volume",  intent: "Cmd.VolumeDecrease", matchType: .contains),
            R(keyword: "volume down",           intent: "Cmd.VolumeDecrease", matchType: .contains),
            R(keyword: "turn it down",          intent: "Cmd.VolumeDecrease", matchType: .contains),
            R(keyword: "quieter",               intent: "Cmd.VolumeDecrease", matchType: .contains),
            R(keyword: "lower the volume",      intent: "Cmd.VolumeDecrease", matchType: .contains),
            R(keyword: "mute",                  intent: "Cmd.VolumeMute",     matchType: .contains),

            // Media / transcription
            R(keyword: "stop streaming",        intent: "Cmd.StreamingStop",    matchType: .contains),
            R(keyword: "start streaming",       intent: "Cmd.StreamingStart",   matchType: .contains),
            R(keyword: "begin streaming",       intent: "Cmd.StreamingStart",   matchType: .contains),
            R(keyword: "transcribe",            intent: "Cmd.TranscribeStart",  matchType: .contains),
            R(keyword: "translate",             intent: "Cmd.TranslationStart", matchType: .contains),

            // Device
            R(keyword: "find my phone",         intent: "Cmd.FindMyPhone",  matchType: .contains),
            R(keyword: "where is my phone",     intent: "Cmd.FindMyPhone",  matchType: .contains),
            R(keyword: "check battery",         intent: "Cmd.BatteryLevel", matchType: .contains),
            R(keyword: "battery level",         intent: "Cmd.BatteryLevel", matchType: .contains),
            R(keyword: "how much battery",      intent: "Cmd.BatteryLevel", matchType: .contains),

            // Memory / program
            R(keyword: "change memory",         intent: "Cmd.MemoryChange", matchType: .contains),
            R(keyword: "switch memory",         intent: "Cmd.MemoryChange", matchType: .contains),
            R(keyword: "change program",        intent: "Cmd.MemoryChange", matchType: .contains),
            R(keyword: "switch program",        intent: "Cmd.MemoryChange", matchType: .contains),

            // Messages
            R(keyword: "send a message",        intent: "Cmd.SendMessage",   matchType: .contains),
            R(keyword: "send message",          intent: "Cmd.SendMessage",   matchType: .contains),
            R(keyword: "listen to message",     intent: "Cmd.ListenMessage", matchType: .contains),
            R(keyword: "play my message",       intent: "Cmd.ListenMessage", matchType: .contains),
        ]
    }
}
