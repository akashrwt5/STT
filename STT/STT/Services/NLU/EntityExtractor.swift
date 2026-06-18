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

public final class EntityExtractor: @unchecked Sendable {

    /// Raw config per entity (type, fuzzy, open flags) from nlu_entities.json.
    private struct EntityConfig {
        let type: String
        let fuzzy: Bool
        let open: Bool
    }

    private let configs: [String: EntityConfig]
    /// Flattened synonym → canonical-value lookup per enum entity.
    private let lookups: [String: [String: String]]

    // MARK: - Init

    public init(entitiesURL: URL? = Bundle.main.url(forResource: "nlu_entities", withExtension: "json")) {
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
    }

    // MARK: - Public entry point

    /// Extracts the value for `entity` from `text`. Returns nil if not found.
    public func extract(_ entity: String, from text: String) -> String? {
        switch entity {
        case "sys.date-time":      return extractDateTime(text)?.iso
        case "sys.number-integer": return extractNumber(text).map { String($0) }
        default:                   return extractEnum(entity, from: text)
        }
    }

    /// Whether an entity is an "open" topic (free text allowed beyond the synonym table).
    public func isOpen(_ entity: String) -> Bool {
        configs[entity]?.open ?? false
    }

    // MARK: - Enum entities

    private func extractEnum(_ entity: String, from text: String) -> String? {
        guard let table = lookups[entity] else { return nil }
        let t = text.lowercased()

        // Longest synonyms first, whole-word match.
        for syn in table.keys.sorted(by: { $0.count > $1.count }) {
            if matchesWholeWord(syn, in: t) {
                return table[syn]
            }
        }

        // Fuzzy fallback (single-token Levenshtein within 30% of synonym length).
        if configs[entity]?.fuzzy == true {
            let tokens = tokenize(t)
            var best: String?
            var bestDistance = Int.max
            for (syn, canon) in table {
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
    /// `timeExplicit` is true when the user actually specified a time-of-day
    /// (clock time, relative duration, or a named period like "morning"); false
    /// when only a day was given and the time was defaulted. The engine uses it
    /// to prompt for a missing time while keeping the resolved day.
    public struct DateTimeMatch {
        public let iso: String
        public let span: String
        public let timeExplicit: Bool
        /// True when the text named a day ("tomorrow", "friday"). The engine uses
        /// this so a follow-up answer that repeats a day wins over a parked day
        /// instead of anchoring onto it (which would advance the date).
        public let explicitDay: Bool
    }

    // Faithful port of IntentClassifier/scripts/nlu/entities.py extract_datetime.
    // Keep the two in sync — the on-device result must match the server.
    public func extractDateTime(_ text: String, now: Date = Date()) -> DateTimeMatch? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        var t = text.lowercased().trimmingCharacters(in: .whitespaces)

        func atDay(_ day: Date, _ h: Int, _ mn: Int) -> Date? {
            var c = cal.dateComponents([.year, .month, .day], from: day)
            c.hour = h; c.minute = mn; c.second = 0
            return cal.date(from: c)
        }

        // --- 1. Relative durations ---
        if let m = firstMatch(#"\bin\s+(\d+)\s*(minute|min|hour|hr|day|week)s?\b"#, in: t),
           let n = Int(m.group(1)),
           let d = cal.date(byAdding: relComps(m.group(2), n), to: now) {
            return DateTimeMatch(iso: isoMinutes(d), span: m.group(0), timeExplicit: true, explicitDay: false)
        }
        if let m = firstMatch(#"\bin\s+an?\s+(minute|min|hour|hr|day|week)s?\b"#, in: t),
           let d = cal.date(byAdding: relComps(m.group(1), 1), to: now) {
            return DateTimeMatch(iso: isoMinutes(d), span: m.group(0), timeExplicit: true, explicitDay: false)
        }
        if let m = firstMatch(#"\bin\s+(?:a\s+few|a\s+couple\s+(?:of\s+)?)\s*(minute|min|hour|hr)s?\b"#, in: t),
           let d = cal.date(byAdding: relComps(m.group(1), m.group(0).contains("few") ? 3 : 2), to: now) {
            return DateTimeMatch(iso: isoMinutes(d), span: m.group(0), timeExplicit: true, explicitDay: false)
        }
        if firstMatch(#"\bin\s+half\s+an?\s+hour\b"#, in: t) != nil,
           let d = cal.date(byAdding: .minute, value: 30, to: now) {
            return DateTimeMatch(iso: isoMinutes(d), span: "in half an hour", timeExplicit: true, explicitDay: false)
        }

        // --- 2. Explicit past-date rejection ---
        if matchesWholeWord("yesterday", in: t) { return nil }

        // --- 3. Normalise word numbers ("nine pm" -> "9 pm") ---
        t = normaliseWordNumbers(t)

        // --- 4. Day anchor (day-after-tomorrow before tomorrow) ---
        var baseDay = now
        var span: String?
        var explicitDay = false
        if firstMatch(#"\bday\s+after\s+tomorrow\b"#, in: t) != nil {
            baseDay = cal.date(byAdding: .day, value: 2, to: now) ?? now
            span = "day after tomorrow"; explicitDay = true
        } else if matchesWholeWord("tomorrow", in: t) {
            baseDay = cal.date(byAdding: .day, value: 1, to: now) ?? now
            span = "tomorrow"; explicitDay = true
        } else if matchesWholeWord("today", in: t) || matchesWholeWord("tonight", in: t) {
            baseDay = now; span = "today"; explicitDay = true
        } else if firstMatch(#"\bnext\s+week\b"#, in: t) != nil {
            baseDay = cal.date(byAdding: .day, value: 7, to: now) ?? now
            span = "next week"; explicitDay = true
        } else {
            let nowWeekday = (cal.component(.weekday, from: now) + 5) % 7 // Mon=0..Sun=6
            for (i, wd) in Self.weekdays.enumerated() where matchesWholeWord(wd, in: t) {
                var ahead = (i - nowWeekday) % 7
                if ahead <= 0 { ahead += 7 }
                baseDay = cal.date(byAdding: .day, value: ahead, to: now) ?? now
                span = wd; explicitDay = true
                break
            }
        }

        // --- 5. Period hint (word boundaries: "tonight" must not match "night") ---
        var period: String?
        if matchesWholeWord("morning", in: t)        { period = "morning" }
        else if matchesWholeWord("afternoon", in: t) { period = "afternoon" }
        else if matchesWholeWord("evening", in: t)   { period = "evening" }
        else if matchesWholeWord("night", in: t)     { period = "night" }
        else if matchesWholeWord("tonight", in: t)   { period = "evening" }
        else if matchesWholeWord("noon", in: t)      { period = "noon" }
        else if matchesWholeWord("midnight", in: t)  { period = "midnight" }

        let namedHour = ["morning": 8, "afternoon": 14, "evening": 18,
                         "night": 21, "noon": 12, "midnight": 0]

        // --- 6. Explicit time extraction ---
        var hour: Int?
        var minute: Int?
        var explicitAmpm = false

        if let m = firstMatch(#"\bhalf\s+past\s+(\d{1,2})\b"#, in: t) {
            hour = Int(m.group(1)); minute = 30; span = m.group(0)
        }
        if hour == nil, let m = firstMatch(#"\bquarter\s+past\s+(\d{1,2})\b"#, in: t) {
            hour = Int(m.group(1)); minute = 15; span = m.group(0)
        }
        if hour == nil, let m = firstMatch(#"\bquarter\s+to\s+(\d{1,2})\b"#, in: t),
           let h = Int(m.group(1)), (1...12).contains(h) {
            hour = h > 1 ? h - 1 : 12; minute = 45; span = m.group(0)
        }
        if hour == nil, let m = firstMatch(#"\b(\d{1,2})\s+past\s+(\d{1,2})\b"#, in: t),
           let mm = Int(m.group(1)), let hh = Int(m.group(2)), (0...59).contains(mm), (1...12).contains(hh) {
            minute = mm; hour = hh; span = m.group(0)
        }
        if hour == nil, let m = firstMatch(#"\b(\d{1,2})\s+to\s+(\d{1,2})\b"#, in: t),
           let mins = Int(m.group(1)), let h = Int(m.group(2)), (1...59).contains(mins), (1...12).contains(h) {
            hour = h > 1 ? h - 1 : 12; minute = 60 - mins; span = m.group(0)
        }
        // "9am", "9 am", "9:30pm"
        if hour == nil, let m = firstMatch(#"\b(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s*m\.?\b"#, in: t) {
            let raw = Int(m.group(1)) ?? 0
            hour = raw % 12 + (m.group(3) == "p" ? 12 : 0)
            minute = Int(m.group(2)) ?? 0
            span = m.group(0); explicitAmpm = true
        }
        // "9:30" colon, no am/pm
        if hour == nil, let m = firstMatch(#"\b(\d{1,2}):(\d{2})\b"#, in: t) {
            hour = Int(m.group(1)); minute = Int(m.group(2)); span = m.group(0)
        }
        // "at N M" (at 9 30)
        if hour == nil, let m = firstMatch(#"\bat\s+(\d{1,2})\s+(\d{2})\b"#, in: t) {
            hour = Int(m.group(1)); minute = Int(m.group(2)); span = m.group(0)
        }
        // "at N" anywhere, else a bare number as the whole input
        if hour == nil {
            if let m = firstMatch(#"\bat\s+(\d{1,2})\b"#, in: t) {
                hour = Int(m.group(1)); minute = 0; span = m.group(0)
            } else if let m = firstMatch(#"^(\d{1,2})\s*$"#, in: t) {
                hour = Int(m.group(1)); minute = 0; span = m.group(0)
            }
        }
        // "9 30" space-separated H MM
        if hour == nil, let m = firstMatch(#"\b(\d{1,2})\s+(\d{2})\b"#, in: t),
           let mm = Int(m.group(2)), (0...59).contains(mm) {
            hour = Int(m.group(1)); minute = mm; span = m.group(0)
        }
        // Digit paired with a period word: "9 in the morning"
        if hour == nil, let p = period, p != "am", p != "pm",
           let m = firstMatch(#"\b(\d{1,2})\b"#, in: t), let h = Int(m.group(1)), (1...12).contains(h) {
            hour = h; minute = 0; span = m.group(0)
        }
        // Named time only (no digit)
        if hour == nil, let p = period, let h = namedHour[p] {
            hour = h; minute = 0; span = p
        }

        // --- 7. Build ---
        if let h = hour {
            let mn = minute ?? 0
            guard (0...59).contains(mn) else { return nil }
            var date: Date
            if (1...12).contains(h) && !explicitAmpm && period != "am" {
                date = pickFutureHour(h, mn, baseDay, now, period, cal)
            } else {
                guard (0...23).contains(h), let d = atDay(baseDay, h, mn) else { return nil }
                date = d
                if !explicitDay && date <= now {
                    date = cal.date(byAdding: .day, value: 1, to: date) ?? date
                }
            }
            // Reject an explicitly past day.
            if explicitDay && cal.startOfDay(for: baseDay) < cal.startOfDay(for: now) { return nil }
            return DateTimeMatch(iso: isoMinutes(date), span: span ?? "",
                                 timeExplicit: true, explicitDay: explicitDay)
        }

        if explicitDay, let d = atDay(baseDay, 9, 0) {
            // Day with no time — defaulted to 9am, flagged not-explicit so the
            // engine prompts for the time while keeping this day.
            return DateTimeMatch(iso: isoMinutes(d), span: span ?? "",
                                 timeExplicit: false, explicitDay: true)
        }
        return nil
    }

    private func relComps(_ unit: String, _ n: Int) -> DateComponents {
        var c = DateComponents()
        switch unit {
        case "minute", "min": c.minute = n
        case "hour", "hr":    c.hour = n
        case "day":           c.day = n
        case "week":          c.day = n * 7
        default: break
        }
        return c
    }

    /// Mirror of entities.py _pick_future_hour: resolve a 1-12 hour to the next
    /// future instant, using a period hint or the "1-6 means PM" heuristic.
    private func pickFutureHour(_ h: Int, _ minute: Int, _ baseDay: Date,
                                _ now: Date, _ period: String?, _ cal: Calendar) -> Date {
        func atDay(_ day: Date, _ hr: Int, _ mn: Int) -> Date {
            var c = cal.dateComponents([.year, .month, .day], from: day)
            c.hour = hr; c.minute = mn; c.second = 0
            return cal.date(from: c) ?? day
        }
        var h24: Int
        if period == "am" || period == "morning" {
            h24 = h % 12
        } else if period == "pm" || period == "afternoon" || period == "evening" || period == "night" {
            h24 = h % 12 + 12
        } else {
            h24 = (1...6).contains(h) ? h + 12 : h   // 1-6 → PM, else AM
        }
        var dt = atDay(baseDay, h24, minute)
        if dt <= now && cal.isDate(baseDay, inSameDayAs: now) && period == nil {
            let alt = h24 < 12 ? h24 + 12 : h24 - 12
            if (0...23).contains(alt) {
                let dtAlt = atDay(baseDay, alt, minute)
                if dtAlt > now { return dtAlt }
            }
        }
        if dt <= now { dt = cal.date(byAdding: .day, value: 1, to: dt) ?? dt }
        return dt
    }

    private static let wordNums: [(String, Int)] = [
        ("seventeen", 17), ("thirteen", 13), ("fourteen", 14), ("eighteen", 18),
        ("nineteen", 19), ("sixteen", 16), ("fifteen", 15), ("eleven", 11),
        ("twelve", 12), ("twenty", 20), ("thirty", 30), ("forty", 40), ("fifty", 50),
        ("three", 3), ("seven", 7), ("eight", 8), ("four", 4), ("five", 5),
        ("nine", 9), ("one", 1), ("two", 2), ("six", 6), ("ten", 10),
    ]

    /// Replace spoken number words with digits (longest first) so the clock
    /// regexes work uniformly. Mirrors entities.py _normalise_word_numbers.
    private func normaliseWordNumbers(_ text: String) -> String {
        var t = text
        for (word, val) in Self.wordNums {
            t = t.replacingOccurrences(of: "\\b\(word)\\b", with: String(val),
                                       options: [.regularExpression, .caseInsensitive])
        }
        return t
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
