// EntityExtractor.swift
// STT
//
// The @entity layer of Dialogflow, reimplemented on-device.
// Mirrors IntentClassifier/scripts/nlu/entities.py.
//
// Two kinds of entities:
//   - enum entities  (@memory, @recurrence, @remind): value/synonym table from nlu_entities.json
//   - system entities (@sys.date-time, @sys.number-integer): rule-based parsers

import Foundation
import os.log

public final class EntityExtractor: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.stt.module", category: "EntityExtractor")

    /// Raw config per entity (type, fuzzy, open flags) from nlu_entities.json.
    private struct EntityConfig {
        let type: String
        let fuzzy: Bool
        let open: Bool
    }

    private let configs: [String: EntityConfig]
    /// Flattened synonym → canonical-value lookup per enum entity.
    private let lookups: [String: [String: String]]
    /// Synonyms pre-sorted longest-first, built once at init to avoid per-call sort cost.
    private let sortedLookups: [String: [(key: String, value: String)]]

    // MARK: - Init

    public init(entitiesURL: URL? = Bundle(for: EntityExtractor.self).url(forResource: "nlu_entities", withExtension: "json")) {
        guard
            let url = entitiesURL,
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            fatalError("EntityExtractor: nlu_entities.json not found in app bundle.")
        }

        var configs: [String: EntityConfig] = [:]
        var lookups: [String: [String: String]] = [:]

        for (name, raw) in root {
            guard let cfg = raw as? [String: Any] else { continue }
            let type = cfg["type"] as? String ?? "enum"
            configs[name] = EntityConfig(
                type: type,
                fuzzy: cfg["fuzzy"] as? Bool ?? false,
                open: cfg["open"] as? Bool ?? false
            )

            if type == "enum", let values = cfg["values"] as? [String: [String]] {
                var table: [String: String] = [:]
                for (value, synonyms) in values {
                    table[value.lowercased()] = value
                    for syn in synonyms {
                        table[syn.lowercased()] = value
                    }
                }
                lookups[name] = table
            }
        }

        self.configs = configs
        self.lookups = lookups
        self.sortedLookups = lookups.mapValues { table in
            table.map { (key: $0.key, value: $0.value) }
                 .sorted { $0.key.count > $1.key.count }
        }
    }

    // MARK: - Public entry point

    /// Extracts the value for `entity` from `text`. Returns nil if not found.
    public func extract(_ entity: String, from text: String) -> String? {
        let t0 = Date()
        let result: String?
        switch entity {
        case "sys.date-time":      result = extractDateTime(text)?.iso
        case "sys.number-integer": result = extractNumber(text).map { String($0) }
        default:                   result = extractEnum(entity, from: text)
        }
        let ms = Date().timeIntervalSince(t0) * 1_000
        logger.info("[Timing] EntityExtractor.extract(\(entity)) → \(result ?? "nil") | \(String(format: "%.2f", ms))ms")
        return result
    }

    /// Whether an entity is an "open" topic (free text allowed beyond the synonym table).
    public func isOpen(_ entity: String) -> Bool {
        configs[entity]?.open ?? false
    }

    // MARK: - Enum entities

    private func extractEnum(_ entity: String, from text: String) -> String? {
        guard let sorted = sortedLookups[entity] else { return nil }
        let t = text.lowercased()

        // Longest synonyms first, whole-word match. Order pre-computed at init.
        let matchStart = Date()
        var iterations = 0
        for entry in sorted {
            iterations += 1
            if matchesWholeWord(entry.key, in: t) {
                let matchMs = Date().timeIntervalSince(matchStart) * 1_000
                logger.info("[Timing] extractEnum(\(entity)) exact-match: match=\(String(format: "%.2f", matchMs))ms iters=\(iterations)/\(sorted.count) → '\(entry.value)'")
                return entry.value
            }
        }
        let matchMs = Date().timeIntervalSince(matchStart) * 1_000
        logger.info("[Timing] extractEnum(\(entity)) exact-match: match=\(String(format: "%.2f", matchMs))ms iters=\(iterations)/\(sorted.count) → no match")

        // Fuzzy fallback (single-token Levenshtein within 30% of synonym length).
        if configs[entity]?.fuzzy == true {
            let fuzzyStart = Date()
            let tokens = tokenize(t)
            var best: String?
            var bestDistance = Int.max
            for (syn, canon) in sorted {
                if syn.contains(" ") || syn.count < 3 { continue }
                let limit = max(1, Int((Double(syn.count) * 0.3).rounded()))
                for tok in tokens {
                    if abs(tok.count - syn.count) > limit { continue }
                    let d = levenshtein(tok, syn)
                    if d <= limit && d < bestDistance {
                        best = canon
                        bestDistance = d
                    }
                }
            }
            let fuzzyMs = Date().timeIntervalSince(fuzzyStart) * 1_000
            logger.info("[Timing] extractEnum(\(entity)) fuzzy: \(String(format: "%.2f", fuzzyMs))ms → \(best ?? "nil")")
            if let best { return best }
        }
        return nil
    }

    // MARK: - Number entity

    private static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60,
    ]

    private func extractNumber(_ text: String) -> Int? {
        let t = text.lowercased()
        if let range = t.range(of: #"\b\d+\b"#, options: .regularExpression) {
            return Int(t[range])
        }
        for (word, val) in Self.numberWords {
            if matchesWholeWord(word, in: t) { return val }
        }
        return nil
    }

    // MARK: - Date-time entity

    private static let weekdays = ["monday", "tuesday", "wednesday", "thursday",
                                   "friday", "saturday", "sunday"]

    /// Parsed date-time result with the ISO string and the matched text span.
    public struct DateTimeMatch { public let iso: String; public let span: String }

    public func extractDateTime(_ text: String, now: Date = Date()) -> DateTimeMatch? {
        let dtStart = Date()
        defer {
            let ms = Date().timeIntervalSince(dtStart) * 1_000
            logger.info("[Timing] extractDateTime() total: \(String(format: "%.2f", ms))ms")
        }
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current

        // "in N minutes / hours / days / weeks"
        if let m = firstMatch(#"\bin\s+(\d+)\s*(minute|min|hour|hr|day|week)s?\b"#, in: t),
           let n = Int(m.group(1)) {
            let unit = m.group(2)
            var comps = DateComponents()
            switch unit {
            case "minute", "min": comps.minute = n
            case "hour", "hr":    comps.hour = n
            case "day":           comps.day = n
            case "week":          comps.day = n * 7
            default: break
            }
            if let date = cal.date(byAdding: comps, to: now) {
                return DateTimeMatch(iso: isoMinutes(date), span: m.group(0))
            }
        }

        // Base day: tomorrow / today / tonight / weekday
        var baseDay = now
        var span: String?
        if matchesWholeWord("tomorrow", in: t) {
            baseDay = cal.date(byAdding: .day, value: 1, to: now) ?? now
            span = "tomorrow"
        } else if matchesWholeWord("today", in: t) || matchesWholeWord("tonight", in: t) {
            baseDay = now
            span = "today"
        } else {
            let nowWeekday = (cal.component(.weekday, from: now) + 5) % 7 // Mon=0..Sun=6
            for (i, wd) in Self.weekdays.enumerated() {
                if matchesWholeWord(wd, in: t) {
                    var ahead = (i - nowWeekday) % 7
                    if ahead <= 0 { ahead += 7 }
                    baseDay = cal.date(byAdding: .day, value: ahead, to: now) ?? now
                    span = wd
                    break
                }
            }
        }

        // Time of day: explicit clock, then named parts of day.
        var hour: Int?
        var minute: Int?
        if let m = firstMatch(#"\b(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s*m\.?\b"#, in: t) {
            let h12 = Int(m.group(1)) ?? 0
            hour = (h12 % 12) + (m.group(3) == "p" ? 12 : 0)
            minute = Int(m.group(2)) ?? 0
            span = m.group(0)
        } else if let m = firstMatch(#"\b(\d{1,2}):(\d{2})\b"#, in: t) {
            hour = Int(m.group(1))
            minute = Int(m.group(2))
            span = m.group(0)
        }

        if hour == nil {
            if t.contains("morning")        { hour = 8;  minute = 0; span = span ?? "morning" }
            else if t.contains("afternoon") { hour = 14; minute = 0; span = span ?? "afternoon" }
            else if t.contains("evening")   { hour = 18; minute = 0; span = span ?? "evening" }
            else if t.contains("night")     { hour = 21; minute = 0; span = span ?? "night" }
            else if t.contains("noon")      { hour = 12; minute = 0; span = span ?? "noon" }
        }

        guard hour != nil || span != nil else { return nil }

        var comps = cal.dateComponents([.year, .month, .day], from: baseDay)
        comps.hour = hour ?? 9
        comps.minute = minute ?? 0
        comps.second = 0
        guard var date = cal.date(from: comps) else { return nil }

        // If the resolved time is in the past for *today*, roll forward a day.
        if span != "tomorrow",
           date < now,
           cal.isDate(baseDay, inSameDayAs: now) {
            date = cal.date(byAdding: .day, value: 1, to: date) ?? date
        }

        return DateTimeMatch(iso: isoMinutes(date), span: span ?? "")
    }

    // MARK: - Topic stripping (for open slots)

    private static let timePatterns: [String] = [
        #"\bin\s+\d+\s*(?:minute|min|hour|hr|day|week)s?\b"#,
        #"\b\d{1,2}(?::\d{2})?\s*[ap]\.?\s*m\.?\b"#,
        #"\b\d{1,2}:\d{2}\b"#,
        #"\b(?:tomorrow|today|tonight)\b"#,
        #"\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)s?\b"#,
        #"\b(?:every|each)\s+\w+\b"#,
        #"\b(?:morning|afternoon|evening|night|noon)\b"#,
        #"\b(?:at|on|by|this|next)\b"#,
    ]

    /// Removes date/time fragments so the remaining text can be used as an open topic.
    public func stripDateTime(_ text: String) -> String {
        var t = text
        for pattern in Self.timePatterns {
            t = t.replacingOccurrences(
                of: pattern, with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
    }

    // MARK: - Helpers

    private func isoMinutes(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.string(from: date)
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func matchesWholeWord(_ word: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return text.range(of: "\\b\(escaped)\\b", options: .regularExpression) != nil
    }

    private func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        for i in 1...aChars.count {
            var cur = [i]
            for j in 1...bChars.count {
                let cost = aChars[i-1] == bChars[j-1] ? 0 : 1
                cur.append(min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost))
            }
            prev = cur
        }
        return prev[bChars.count]
    }

    // MARK: - Lightweight regex match wrapper

    private struct RegexMatch {
        private let groups: [String]
        init(_ groups: [String]) { self.groups = groups }
        func group(_ i: Int) -> String { i < groups.count ? groups[i] : "" }
    }

    private func firstMatch(_ pattern: String, in text: String) -> RegexMatch? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append("")
            }
        }
        return RegexMatch(groups)
    }
}
