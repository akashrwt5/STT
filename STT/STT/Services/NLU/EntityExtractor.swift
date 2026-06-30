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

    /// Reverse-lookup tables built once from an `NLULexicon` for the
    /// lexicon-driven datetime parser. `nil` for English (or no lexicon), in
    /// which case `extractDateTime`/`stripDateTime` run the byte-identical
    /// English path. Mirrors the `_lex_*` tables in entities.py.
    private let lex: LexTables?

    private struct LexTables {
        let is24h: Bool
        let conj: String?                                  // lowercased joiner
        let idioms: [(phrase: String, minutes: Int?, hour: Int?)]   // longest-first
        let weekday: [(syn: String, idx: Int)]             // longest-first, Mon=0..Sun=6
        let month: [String: Int]                           // synonym → 1..12
        let monthAlt: [String]                             // synonyms, longest-first
        let number: [String: Int]                          // synonym → int
        let numberPhrases: [(phrase: String, val: Int)]    // longest-first
        let period: [(name: String, hour: Int)]            // longest-first
        let dayAnchor: [(phrase: String, key: String)]     // longest-first
        let unit: [String: String]                         // synonym → canonical unit
        let unitAlt: [String]                              // synonyms, longest-first
        let inMarkers: [String]                            // longest-first
        let atMarkers: [String]                            // longest-first
    }

    private static let weekdayOrder = ["Monday", "Tuesday", "Wednesday", "Thursday",
                                       "Friday", "Saturday", "Sunday"]
    private static let monthOrder = ["January", "February", "March", "April", "May", "June",
                                     "July", "August", "September", "October", "November", "December"]

    // MARK: - Init

    public init(entitiesURL: URL? = Bundle.main.url(forResource: "nlu_entities", withExtension: "json"),
                lexicon: NLULexicon? = nil) {
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
        self.lex = lexicon.map(Self.buildLexTables)
    }

    /// Builds the reverse-lookup tables. Ordering is deterministic — phrase scans
    /// sort by (length desc, value asc) so Swift and Python pick the same phrase
    /// on every tie; this is required for the golden-fixture parity gate.
    private static func buildLexTables(_ lex: NLULexicon) -> LexTables {
        func longestFirst(_ a: String, _ b: String) -> Bool {
            a.count != b.count ? a.count > b.count : a < b
        }

        let g = lex.grammar
        let idioms = (g?.decimalHourIdioms ?? [])
            .filter { !$0.phrase.isEmpty }
            .map { (phrase: $0.phrase.lowercased(), minutes: $0.minutes, hour: $0.hour) }
            .sorted { longestFirst($0.phrase, $1.phrase) }

        var weekday: [(syn: String, idx: Int)] = []
        for (idx, name) in weekdayOrder.enumerated() {
            for syn in lex.weekdays[name] ?? [] { weekday.append((syn.lowercased(), idx)) }
        }
        weekday.sort { longestFirst($0.syn, $1.syn) }

        var month: [String: Int] = [:]
        for (mi, name) in monthOrder.enumerated() {
            for syn in lex.months[name] ?? [] { month[syn.lowercased()] = mi + 1 }
        }
        let monthAlt = month.keys.sorted { longestFirst($0, $1) }

        var number: [String: Int] = [:]
        for (k, syns) in lex.numbers0to31 { if let v = Int(k) { for s in syns { number[s.lowercased()] = v } } }
        for (k, syns) in lex.ordinals1to31 { if let v = Int(k) { for s in syns { number[s.lowercased()] = v } } }
        let numberPhrases = number.map { (phrase: $0.key, val: $0.value) }
            .sorted { longestFirst($0.phrase, $1.phrase) }

        var period: [(name: String, hour: Int)] = []
        for entry in lex.timeOfDay.values { for n in entry.names { period.append((n.lowercased(), entry.hour)) } }
        period.sort { longestFirst($0.name, $1.name) }

        var dayAnchor: [(phrase: String, key: String)] = []
        for (key, phrases) in lex.dayAnchors { for p in phrases { dayAnchor.append((p.lowercased(), key)) } }
        dayAnchor.sort { longestFirst($0.phrase, $1.phrase) }

        var unit: [String: String] = [:]
        for (canon, syns) in lex.relativeUnits { for s in syns { unit[s.lowercased()] = canon } }
        let unitAlt = unit.keys.sorted { longestFirst($0, $1) }

        let inMarkers = (lex.relativeMarkers["in"] ?? []).map { $0.lowercased() }.sorted { longestFirst($0, $1) }
        let atMarkers = (lex.relativeMarkers["at"] ?? []).map { $0.lowercased() }.sorted { longestFirst($0, $1) }

        let conj = g?.conjunction?.lowercased()
        return LexTables(
            is24h: (g?.timeFormat ?? "24h") == "24h",
            conj: (conj?.isEmpty == false) ? conj : nil,
            idioms: idioms, weekday: weekday, month: month, monthAlt: monthAlt,
            number: number, numberPhrases: numberPhrases, period: period,
            dayAnchor: dayAnchor, unit: unit, unitAlt: unitAlt,
            inMarkers: inMarkers, atMarkers: atMarkers
        )
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
        // Non-English: drive the whole parse from the language lexicon. The
        // English body below is left byte-identical for the no-lexicon case.
        if let lex = lex {
            return extractDateTimeLexicon(text, now: now, lex: lex)
        }

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
        // P0-6: Continental European "15h30", "9h" (French "9h30", German written 24h)
        if hour == nil, let m = firstMatch(#"\b(\d{1,2})h(\d{2})?\b"#, in: t) {
            hour = Int(m.group(1))
            minute = m.group(2).isEmpty ? 0 : (Int(m.group(2)) ?? 0)
            span = m.group(0)
        }
        // P0-6: Danish/German decimal notation "15.30" (minute block 00-59 to avoid matching decimals)
        if hour == nil, let m = firstMatch(#"\b(\d{1,2})\.(\d{2})\b"#, in: t),
           let mm = Int(m.group(2)), (0...59).contains(mm) {
            hour = Int(m.group(1)); minute = mm; span = m.group(0)
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

    // MARK: - Lexicon-driven datetime parser (fr/de/da)
    //
    // Verbatim mirror of entities.py `_extract_datetime_lex`. Both are validated
    // against the same golden CSV fixtures (the Phase 2 parity gate). Any change
    // here must be made identically in Python.

    /// Unicode-Latin-aware word boundaries (keep fr/de/da accents as letters).
    private static let wbL = #"(?<![0-9A-Za-zÀ-ÿ])"#
    private static let wbR = #"(?![0-9A-Za-zÀ-ÿ])"#

    private func extractDateTimeLexicon(_ text: String, now: Date, lex: LexTables) -> DateTimeMatch? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        var t = text.lowercased().trimmingCharacters(in: .whitespaces)
        let span = text.trimmingCharacters(in: .whitespaces)

        func atDay(_ day: Date, _ h: Int, _ mn: Int) -> Date? {
            var c = cal.dateComponents([.year, .month, .day], from: day)
            c.hour = h; c.minute = mn; c.second = 0
            return cal.date(from: c)
        }
        func nowWeekday() -> Int { (cal.component(.weekday, from: now) + 5) % 7 }  // Mon=0..Sun=6

        // A. Relative durations: "<in> N <unit>"
        if !lex.inMarkers.isEmpty && !lex.unit.isEmpty {
            let inAlt = lex.inMarkers.map(Self.esc).joined(separator: "|")
            let uAlt  = lex.unitAlt.map(Self.esc).joined(separator: "|")
            let pat = Self.wbL + "(?:\(inAlt))\\s+(\\d+)\\s+(\(uAlt))" + Self.wbR
            if let m = lexMatch(pat, in: t), let n = Int(m.groups[1]),
               let canon = lex.unit[m.groups[2].lowercased()], let d = addRelative(canon, n, to: now, cal: cal) {
                return DateTimeMatch(iso: isoMinutes(d), span: span, timeExplicit: true, explicitDay: false)
            }
        }

        // B. yesterday / past rejection
        for (phrase, key) in lex.dayAnchor where key == "yesterday" {
            if lexMatch(lexBoundary(phrase), in: t) != nil { return nil }
        }

        t = lexNormaliseNumbers(t, lex)
        var baseDay = now
        var explicitDay = false
        var consumedAnchor = false

        // C. Day anchor (longest phrase first)
        let anchorOffsets = ["today": 0, "tomorrow": 1, "day_after_tomorrow": 2,
                             "next_week": 7, "next_month": 30, "next_year": 365]
        for (phrase, key) in lex.dayAnchor {
            if key == "yesterday" { continue }
            guard let m = lexMatch(lexBoundary(phrase), in: t) else { continue }
            if key == "this_weekend" {
                let ahead = ((5 - nowWeekday()) % 7 + 7) % 7
                baseDay = cal.date(byAdding: .day, value: ahead, to: now) ?? now
            } else if let off = anchorOffsets[key] {
                baseDay = cal.date(byAdding: .day, value: off, to: now) ?? now
            } else { continue }
            explicitDay = true; consumedAnchor = true
            t = lexBlank(t, m.range); break
        }

        // C2. Weekday names
        if !consumedAnchor {
            for (syn, idx) in lex.weekday {
                guard let m = lexMatch(lexBoundary(syn), in: t) else { continue }
                var ahead = ((idx - nowWeekday()) % 7 + 7) % 7
                if ahead == 0 { ahead = 7 }
                baseDay = cal.date(byAdding: .day, value: ahead, to: now) ?? now
                explicitDay = true; consumedAnchor = true
                t = lexBlank(t, m.range); break
            }
        }

        // C3. Date of month "<day>[.] <month>"
        if !consumedAnchor && !lex.month.isEmpty {
            let mAlt = lex.monthAlt.map(Self.esc).joined(separator: "|")
            let pat = Self.wbL + "(\\d{1,2})\\.?\\s+(\(mAlt))" + Self.wbR
            if let m = lexMatch(pat, in: t), let day = Int(m.groups[1]), (1...31).contains(day),
               let mon = lex.month[m.groups[2].lowercased()] {
                let year = cal.component(.year, from: now)
                var dc = DateComponents()
                dc.year = year; dc.month = mon; dc.day = day; dc.hour = 9; dc.minute = 0; dc.second = 0
                if var cand = cal.date(from: dc) {
                    if cal.startOfDay(for: cand) < cal.startOfDay(for: now) {
                        dc.year = year + 1; cand = cal.date(from: dc) ?? cand
                    }
                    baseDay = cand; explicitDay = true
                    t = lexBlank(t, m.range)
                }
            }
        }

        // D. Clock time
        var hour: Int?
        var minute: Int?
        if let m = lexMatch(#"\b(\d{1,2}):(\d{2})\b"#, in: t) {
            hour = Int(m.groups[1]); minute = Int(m.groups[2]); t = lexBlank(t, m.range)
        }
        if hour == nil, let m = lexMatch(#"\b(\d{1,2})h(\d{2})?\b"#, in: t) {
            hour = Int(m.groups[1]); minute = m.groups[2].isEmpty ? 0 : Int(m.groups[2]); t = lexBlank(t, m.range)
        }
        if hour == nil, let m = lexMatch(#"\b(\d{1,2})\.(\d{2})\b"#, in: t),
           let mm = Int(m.groups[2]), (0...59).contains(mm) {
            hour = Int(m.groups[1]); minute = mm; t = lexBlank(t, m.range)
        }
        // D1. Digit + spaced hour-unit: "18 h" / "18 heures" (space between digit and unit)
        if hour == nil {
            let hrSyns = lex.unit.filter { $0.value == "hour" }.keys
                .sorted(by: { $0.count > $1.count })
                .map(Self.esc)
                .joined(separator: "|")
            if !hrSyns.isEmpty,
               let m = lexMatch(#"\b(\d{1,2})\s+(?:"# + hrSyns + #")\b"#, in: t) {
                hour = Int(m.groups[1]); minute = 0; t = lexBlank(t, m.range)
            }
        }
        // D2. Absolute idioms (hour set: midi/minuit/Mitternacht/midnat)
        if hour == nil {
            for (phrase, mins, h) in lex.idioms where h != nil {
                guard let m = lexMatch(lexBoundary(phrase), in: t) else { continue }
                hour = h; minute = mins ?? 0; t = lexBlank(t, m.range); break
            }
        }
        // D3. Decimal-hour idioms (minutes set) + adjacent hour number
        if hour == nil {
            for (phrase, mins, h) in lex.idioms {
                guard let mins = mins, h == nil else { continue }
                guard let m = lexMatch(lexBoundary(phrase), in: t) else { continue }
                guard let H = lexAdjacentHour(t, m.range, lex) else { continue }
                if mins >= 0 { hour = H; minute = mins }
                else { hour = ((H - 1) % 24 + 24) % 24; minute = 60 + mins }
                t = lexBlank(t, m.range); break
            }
        }
        // D4. Named hour + conjunction ("15 Uhr 30", "drei Uhr")
        if hour == nil, let conj = lex.conj {
            let pat = #"\b(\d{1,2})\s+"# + Self.esc(conj) + #"(?:\s+(\d{1,2}))?\b"#
            if let m = lexMatch(pat, in: t) {
                hour = Int(m.groups[1]); minute = m.groups[2].isEmpty ? 0 : Int(m.groups[2]); t = lexBlank(t, m.range)
            }
        }
        // D5. "<at> <digit>[:mm]"
        if hour == nil, !lex.atMarkers.isEmpty {
            let atAlt = lex.atMarkers.map(Self.esc).joined(separator: "|")
            let pat = Self.wbL + "(?:\(atAlt))\\s+(\\d{1,2})(?::(\\d{2}))?" + Self.wbR
            if let m = lexMatch(pat, in: t) {
                hour = Int(m.groups[1]); minute = m.groups[2].isEmpty ? 0 : Int(m.groups[2]); t = lexBlank(t, m.range)
            }
        }
        // D6. Bare number as the whole input
        if hour == nil, let m = lexMatch(#"^\s*(\d{1,2})\s*$"#, in: t) {
            hour = Int(m.groups[1]); minute = 0
        }

        // E. Period of day (longest name first)
        var periodHour: Int?
        for (name, ph) in lex.period where lexMatch(lexBoundary(name), in: t) != nil {
            periodHour = ph; break
        }

        // F. Combine
        if let h0 = hour {
            var h = h0
            let mn = minute ?? 0
            guard (0...59).contains(mn) else { return nil }
            if let ph = periodHour, ph >= 13, (1...11).contains(h) { h += 12 }
            guard (0...23).contains(h), var date = atDay(baseDay, h, mn) else { return nil }
            if !explicitDay && date <= now { date = cal.date(byAdding: .day, value: 1, to: date) ?? date }
            if explicitDay && cal.startOfDay(for: baseDay) < cal.startOfDay(for: now) { return nil }
            return DateTimeMatch(iso: isoMinutes(date), span: span, timeExplicit: true, explicitDay: explicitDay)
        }
        if let ph = periodHour, var date = atDay(baseDay, ph, 0) {
            if !explicitDay && date <= now { date = cal.date(byAdding: .day, value: 1, to: date) ?? date }
            return DateTimeMatch(iso: isoMinutes(date), span: span, timeExplicit: true, explicitDay: explicitDay)
        }
        if explicitDay, let date = atDay(baseDay, 9, 0) {
            return DateTimeMatch(iso: isoMinutes(date), span: span, timeExplicit: false, explicitDay: true)
        }
        return nil
    }

    private func addRelative(_ unit: String, _ n: Int, to now: Date, cal: Calendar) -> Date? {
        switch unit {
        case "minute": return cal.date(byAdding: .minute, value: n, to: now)
        case "hour":   return cal.date(byAdding: .hour, value: n, to: now)
        case "day":    return cal.date(byAdding: .day, value: n, to: now)
        case "week":   return cal.date(byAdding: .day, value: 7 * n, to: now)
        case "month":  return cal.date(byAdding: .day, value: 30 * n, to: now)
        case "year":   return cal.date(byAdding: .day, value: 365 * n, to: now)
        default:       return nil
        }
    }

    /// Hour number adjacent to a decimal-hour idiom: look right (skipping the
    /// conjunction and hour-unit words), then left. Mirrors `_lex_adjacent_hour`.
    private func lexAdjacentHour(_ t: String, _ range: Range<String.Index>, _ lex: LexTables) -> Int? {
        var skip = Set<String>()
        if let c = lex.conj { skip.insert(c) }
        for (syn, canon) in lex.unit where canon == "hour" { skip.insert(syn) }
        func firstNumber(_ tokens: [String]) -> Int? {
            for tok in tokens {
                if tok.isEmpty || skip.contains(tok) { continue }
                if tok.range(of: #"^\d{1,2}$"#, options: .regularExpression) != nil { return Int(tok) }
                if let v = lex.number[tok] { return v }
                return nil  // first significant token is not a number → stop
            }
            return nil
        }
        let right = String(t[range.upperBound...])
        if let h = firstNumber(lexTokens(right)) { return h }
        let left = String(t[..<range.lowerBound])
        return firstNumber(Array(lexTokens(left).reversed()))
    }

    private func lexNormaliseNumbers(_ text: String, _ lex: LexTables) -> String {
        var t = text
        for (phrase, val) in lex.numberPhrases {
            t = t.replacingOccurrences(of: lexBoundary(phrase), with: String(val), options: [.regularExpression])
        }
        return t
    }

    // MARK: Lexicon regex helpers

    private static func esc(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

    private func lexBoundary(_ phrase: String) -> String {
        Self.wbL + Self.esc(phrase) + Self.wbR
    }

    private func lexTokens(_ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"[0-9A-Za-zÀ-ÿ]+"#) else { return [] }
        let ns = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, range: ns).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    private func lexBlank(_ t: String, _ range: Range<String.Index>) -> String {
        let count = t.distance(from: range.lowerBound, to: range.upperBound)
        return t.replacingCharacters(in: range, with: String(repeating: " ", count: count))
    }

    /// Case-sensitive (operates on already-lowercased text, like the Python path).
    private func lexMatch(_ pattern: String, in text: String) -> (range: Range<String.Index>, groups: [String])? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: ns), let r = Range(m.range, in: text) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            if let gr = Range(m.range(at: i), in: text) { groups.append(String(text[gr])) } else { groups.append("") }
        }
        return (r, groups)
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
        if let lex = lex { return stripDateTimeLexicon(text, lex) }
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

    /// Lexicon-driven topic stripping. Mirrors entities.py `_strip_datetime_lex`.
    private func stripDateTimeLexicon(_ text: String, _ lex: LexTables) -> String {
        var t = text
        func strip(_ pattern: String) {
            t = t.replacingOccurrences(of: pattern, with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }
        // Language-neutral clock forms.
        strip(#"\b\d{1,2}:\d{2}\b"#)
        strip(#"\b\d{1,2}h\d{0,2}\b"#)
        strip(#"\b\d{1,2}\.\d{2}\b"#)
        // Spaced hour-unit forms: "18 h" / "18 heures" not caught by compact patterns above.
        let hrSyns = lex.unit.filter { $0.value == "hour" }.keys
            .sorted(by: { $0.count > $1.count })
            .map(Self.esc)
            .joined(separator: "|")
        if !hrSyns.isEmpty { strip(#"\b\d{1,2}\s+(?:"# + hrSyns + #")\b"#) }
        // Relative durations "<in> N <unit>".
        if !lex.inMarkers.isEmpty && !lex.unit.isEmpty {
            let inAlt = lex.inMarkers.map(Self.esc).joined(separator: "|")
            let uAlt  = lex.unitAlt.map(Self.esc).joined(separator: "|")
            strip(Self.wbL + "(?:\(inAlt))\\s+\\d+\\s+(?:\(uAlt))" + Self.wbR)
        }
        // Phrase lists: anchors, weekdays, months, periods, idioms (longest first).
        var phrases = lex.dayAnchor.map { $0.phrase }
        phrases += lex.weekday.map { $0.syn }
        phrases += Array(lex.month.keys)
        phrases += lex.period.map { $0.name }
        phrases += lex.idioms.map { $0.phrase }
        for ph in phrases.sorted(by: { $0.count > $1.count }) { strip(lexBoundary(ph)) }
        // Trailing markers + the conjunction.
        var markers = lex.inMarkers + lex.atMarkers
        if let c = lex.conj { markers.append(c) }
        for mk in Set(markers).sorted(by: { $0.count > $1.count }) { strip(lexBoundary(mk)) }
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
