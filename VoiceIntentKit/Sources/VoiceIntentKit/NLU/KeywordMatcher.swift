// KeywordMatcher.swift
// STT
//
// Stage 1 of the 3-stage intent classification pipeline.
// Mirrors _compile_keyword_rules() and _is_negated() in
// IntentClassifier/scripts/nlu/classifier.py.
//
// Calibrated confidence matches Python:
//   exact    = 0.97  (full-string equality)
//   contains = 0.85  (word-boundary match, negation-checked)
//
// ── Word boundaries (device-side fix, BACKPORT to classifier.py) ──────────────
// Keywords are compiled to \b-bounded regexes, NOT substring-matched. Substring
// matching produced unrecoverable false positives — Stage 1 wins at 0.85 before
// Stage 2 ever runs, so these were permanent misfires:
//   "how long is my commute"   → contained "mute"           → Cmd.VolumeMute
//   "my phone is muted"        → contained "mute"           → Cmd.VolumeMute
//   "he transcribed it"        → contained "transcribe"     → Cmd.TranscribeStart
//   "switch programming mode"  → contained "switch program" → Cmd.MemoryChange
// Spaces in keywords compile to \s+ so ASR artifacts (double spaces) still match.
//
// Negation cues are ALSO \b-bounded. The previous substring cues misfired in both
// directions: "piano mute please" was wrongly negated ("no " inside "piano "),
// while "cannot mute" was only negated by luck ("not " inside "cannot ") — so
// "cannot"/"can't"/"cant" are now explicit cues. BACKPORT to classifier.py.
//
// Negation window: 30 chars before the match position are scanned for negation
// cues. "Don't translate this" must NOT fire Cmd.TranslationStart.
// Exact matches are immune to negation (the user literally said just that word).

import Foundation

final class KeywordMatcher {

    // MARK: - Rule type

    enum MatchType { case exact, contains }

    struct Rule {
        let keyword: String
        let intent: String
        let matchType: MatchType
        /// Precompiled \b-bounded pattern; non-nil for `.contains` rules.
        let regex: NSRegularExpression?
        var confidence: Double { matchType == .exact ? 0.97 : 0.85 }
    }

    // MARK: - State

    private let rules: [Rule]

    /// Word-boundary negation scan. Explicit "cannot/can't/cant": with substring
    /// matching they were caught accidentally via "not "; with word boundaries
    /// they need their own alternatives or "cannot mute" would fire the command.
    private static let negationRegex = try! NSRegularExpression(
        pattern: #"\b(?:not|don't|dont|never|without|no|cannot|can't|cant)\b"#,
        options: [.caseInsensitive]
    )

    // MARK: - Init

    init() { rules = Self.buildRules() }

    // MARK: - Public API

    /// Returns the first matching (intent, confidence), or nil.
    /// Rules are evaluated in declaration order — place more specific rules first.
    func match(_ text: String) -> (label: String, confidence: Double)? {
        // Normalise the curly apostrophe ASR sometimes emits (don’t → don't) so
        // apostrophe keywords and negation cues match either form.
        let lower = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }
        let fullRange = NSRange(lower.startIndex..., in: lower)

        for rule in rules {
            switch rule.matchType {
            case .exact:
                if lower == rule.keyword {
                    return (rule.intent, rule.confidence)
                }
            case .contains:
                guard let regex = rule.regex,
                      let m = regex.firstMatch(in: lower, range: fullRange),
                      let matchRange = Range(m.range, in: lower)
                else { continue }
                guard !isNegated(at: matchRange.lowerBound, in: lower) else { continue }
                return (rule.intent, rule.confidence)
            }
        }
        return nil
    }

    // MARK: - Negation detection

    private func isNegated(at position: String.Index, in text: String) -> Bool {
        let distance = text.distance(from: text.startIndex, to: position)
        let windowStart = text.index(position, offsetBy: -min(30, distance))
        let window = String(text[windowStart..<position])
        let range = NSRange(window.startIndex..., in: window)
        return Self.negationRegex.firstMatch(in: window, range: range) != nil
    }

    // MARK: - Pattern compilation

    /// Escapes the keyword, widens literal spaces to `\s+`, and anchors both ends
    /// on word boundaries. All keywords begin and end with word characters, so
    /// `\b` is always well-defined here (asserted in DEBUG at rule build).
    private static func compile(_ keyword: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: keyword)
            .replacingOccurrences(of: " ", with: #"\s+"#)
        return try? NSRegularExpression(pattern: #"\b"# + escaped + #"\b"#)
    }

    // MARK: - Rule definitions

    private static func buildRules() -> [Rule] {
        func R(_ keyword: String, _ intent: String, _ matchType: MatchType = .contains) -> Rule {
            let regex = matchType == .contains ? compile(keyword) : nil
            #if DEBUG
            assert(matchType == .exact || regex != nil,
                   "KeywordMatcher: failed to compile pattern for '\(keyword)'")
            if let first = keyword.unicodeScalars.first, let last = keyword.unicodeScalars.last {
                assert(CharacterSet.alphanumerics.contains(first)
                       && CharacterSet.alphanumerics.contains(last),
                       "KeywordMatcher: '\(keyword)' must start/end on word characters for \\b anchoring")
            }
            #endif
            return Rule(keyword: keyword, intent: intent, matchType: matchType, regex: regex)
        }

        return [
            // Reminders — more specific first
            R("don't let me forget",   "reminders.add"),
            R("dont let me forget",    "reminders.add"),
            R("create a reminder",     "reminders.add"),
            R("set a reminder",        "reminders.add"),
            R("set reminder",          "reminders.add"),
            R("add a reminder",        "reminders.add"),
            R("remind me",             "reminders.add"),
            R("reminder complete",     "reminders.complete"),
            R("mark reminder done",    "reminders.complete"),
            R("complete reminder",     "reminders.complete"),

            // Volume — "off mute"/"unmute" before "mute" so un-muting phrasings
            // never fall through to Cmd.VolumeMute. ("take me off mute" fired
            // Mute before this rule existed — BACKPORT to classifier.py.)
            R("off mute",              "Cmd.VolumeUnmute"),
            R("off of mute",           "Cmd.VolumeUnmute"),
            R("unmute",                "Cmd.VolumeUnmute"),
            R("increase volume",       "Cmd.VolumeIncrease"),
            R("turn up the volume",    "Cmd.VolumeIncrease"),
            R("volume up",             "Cmd.VolumeIncrease"),
            R("turn it up",            "Cmd.VolumeIncrease"),
            R("louder",                "Cmd.VolumeIncrease"),
            R("decrease volume",       "Cmd.VolumeDecrease"),
            R("turn down the volume",  "Cmd.VolumeDecrease"),
            R("volume down",           "Cmd.VolumeDecrease"),
            R("turn it down",          "Cmd.VolumeDecrease"),
            R("quieter",               "Cmd.VolumeDecrease"),
            R("lower the volume",      "Cmd.VolumeDecrease"),
            R("mute",                  "Cmd.VolumeMute"),

            // Media / transcription
            R("stop streaming",        "Cmd.StreamingStop"),
            R("start streaming",       "Cmd.StreamingStart"),
            R("begin streaming",       "Cmd.StreamingStart"),
            R("transcribe",            "Cmd.TranscribeStart"),
            R("translate",             "Cmd.TranslationStart"),

            // Device
            R("find my phone",         "Cmd.FindMyPhone"),
            R("where is my phone",     "Cmd.FindMyPhone"),
            R("check battery",         "Cmd.BatteryLevel"),
            R("battery level",         "Cmd.BatteryLevel"),
            R("how much battery",      "Cmd.BatteryLevel"),

            // Memory / program
            R("change memory",         "Cmd.MemoryChange"),
            R("switch memory",         "Cmd.MemoryChange"),
            R("change program",        "Cmd.MemoryChange"),
            R("switch program",        "Cmd.MemoryChange"),

            // Messages
            R("send a message",        "Cmd.SendMessage"),
            R("send message",          "Cmd.SendMessage"),
            R("listen to message",     "Cmd.ListenMessage"),
            R("play my message",       "Cmd.ListenMessage"),
        ]
    }
}
