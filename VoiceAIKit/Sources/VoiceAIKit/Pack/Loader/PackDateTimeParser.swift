// PackDateTimeParser.swift
// VoiceAIKit
//
// Resolves a date and time from an utterance using ONLY the pack's
// `datetime_grammar`. Replaces the ~890-line `EntityExtractor`, which carried
// English weekday tables, `tomorrow`/`tonight`/`noon` literals and a hardcoded
// `timePatterns` regex array.
//
// There is no English special case here. The Python reference still has two
// paths — a hardcoded English one and a lexicon-driven one for fr/de/da — for
// historical reasons; the pack now carries the full grammar for every language,
// so Swift needs one path. Adding a language is a pack, not a branch.
//
// PARITY IS THE POINT. Branch ORDER and the arithmetic are mirrored from
// `packages/runtime/nlu_engine/entities.py::extract_datetime`, because the two
// runtimes must resolve the same utterance to the same instant. Where a
// constant looks arbitrary it is matching the reference; changing one means
// changing both.
//
// Tables are built ONCE at init (VIK-012): the grammar's lookup properties are
// computed, so touching them per-utterance would rebuild every dictionary.

import Foundation

struct PackDateTimeParser: Sendable {

    // MARK: - Result

    struct Match: Sendable, Equatable {
        /// The resolved instant, in UTC.
        let date: Date
        /// The text that produced it.
        let span: String
        /// True when the user actually said a time. False means only a day was
        /// given ("tomorrow") and the hour was defaulted — the dialog engine
        /// uses this to prompt for the missing time while keeping the day.
        let timeExplicit: Bool
        /// True when the user named a day (anchor, weekday or date).
        let dayExplicit: Bool
    }

    // MARK: - Precompiled grammar

    private let anchorPhrases: [PhraseMatch<String>]
    private let weekdayIndex: [String: Int]
    private let monthIndex: [String: Int]
    private let ordinalPhrases: [PhraseMatch<Int>]
    private let numberIndex: [String: Int]
    private let unitIndex: [String: String]
    private let ordinalContext: [String]
    private let periodHours: [String: Int]
    private let periodPhrases: [PhraseMatch<String>]
    private let yesterdayPhrases: [String]

    private let markersIn: [String]
    private let markersFor: [String]
    /// `relative_markers.at` — the "at" of "at 9". A marker, not an idiom,
    /// which is why it is not in `clockIdioms`.
    private let markersAt: [String]
    private let articles: [String]
    private let quantifiers: [(phrases: [String], n: Int)]
    private let idioms: [String: [String]]
    private let amForms: Set<String>
    private let pmForms: Set<String>
    private let is24Hour: Bool

    // -- topic stripping ----------------------------------------------------
    //
    // One table per alternation in the reference's `_en_strip_patterns`, in the
    // order that function applies them. Built once (VIK-012); the patterns
    // themselves are assembled in `strippingDateTime`.
    private let stripUnits: [String]
    private let stripAmPM: [String]
    /// `strip.at_by` — "at", "by". Removed together with the digit that follows
    /// ("at 7"), which is the only thing stopping an orphan number in the topic.
    private let stripAtBy: [String]
    /// `day_anchors` today/tomorrow/tonight ONLY. `day_after_tomorrow`,
    /// `next_week` and `yesterday` are deliberately absent — the reference
    /// leaves them, and stripping "next week" whole changes the topic.
    private let stripAnchors: [String]
    /// Weekday names, plural-tolerant. See `weekdayStripMinimumLength`.
    private let stripWeekdays: [String]
    /// `strip.recurrence` — removed WITH the word it governs ("every morning").
    private let stripRecurrence: [String]
    /// `strip.the`, used only inside the optional "in the <period>" prefix —
    /// never on its own, or "drink the green tea" loses its article.
    private let stripThe: [String]
    /// `time_of_day` names EXCLUDING midnight, which the reference keeps.
    private let stripPeriods: [String]
    private let stripConnectors: [String]
    /// Spaced clock-hour suffixes ("18 h"). Empty for English, so this is a
    /// no-op on the only language that exists today — see `strippingDateTime`.
    private let clockHourMarkers: [String]

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }
    private let timeZone: TimeZone

    /// Day offsets keyed by canonical ROLE, not by word — a pack maps its own
    /// vocabulary onto these, so they are identifiers and carry no language.
    private static let anchorOffsets: [String: Int] = [
        "today": 0, "tonight": 0, "tomorrow": 1,
        "day_after_tomorrow": 2, "next_week": 7,
    ]

    // MARK: - Init

    init(grammar: DateTimeGrammar, timeZone: TimeZone = .current) {
        self.timeZone = timeZone
        self.anchorPhrases = grammar.dayAnchorPhrasesLongestFirst.filter { $0.value != "yesterday" }
        self.yesterdayPhrases = (grammar.dayAnchors["yesterday"] ?? []).map { $0.lowercased() }
        self.weekdayIndex = grammar.weekdayIndex
        self.monthIndex = grammar.monthIndex
        self.ordinalPhrases = grammar.ordinalPhrasesLongestFirst
        self.numberIndex = grammar.numberIndex
        self.unitIndex = grammar.unitIndex
        self.ordinalContext = grammar.ordinalContextLongestFirst

        var hours: [String: Int] = [:]
        var phrases: [PhraseMatch<String>] = []
        for (role, entry) in grammar.timeOfDay {
            hours[role] = entry.hour
            for name in entry.names {
                phrases.append(PhraseMatch(phrase: name.lowercased(), value: role))
            }
        }
        // "tonight" is a day anchor AND names a time of day, but packs list it
        // only under `day_anchors` — `time_of_day` has evening/night/noon and no
        // "tonight". Without this bridge the utterance resolves to a bare day at
        // the 09:00 default instead of 18:00. The mapping is role→role, so no
        // vocabulary is hardcoded; the words still come from the pack.
        for name in grammar.dayAnchors["tonight"] ?? [] {
            phrases.append(PhraseMatch(phrase: name.lowercased(), value: "evening"))
        }
        self.periodHours = hours
        self.periodPhrases = DateTimeGrammar.longestFirst(phrases)

        self.markersIn = (grammar.relativeMarkers["in"] ?? []).map { $0.lowercased() }
        self.markersFor = (grammar.relativeMarkers["for"] ?? []).map { $0.lowercased() }
        self.markersAt = (grammar.relativeMarkers["at"] ?? []).map { $0.lowercased() }
        self.articles = grammar.articles.map { $0.lowercased() }
        self.quantifiers = grammar.quantifiers.values.map {
            (phrases: $0.phrases.map { p in p.lowercased() }, n: $0.n)
        }
        self.idioms = grammar.clockIdioms.mapValues { $0.map { s in s.lowercased() } }
        self.amForms = Set((grammar.amPM["am"] ?? []).map { $0.lowercased() })
        self.pmForms = Set((grammar.amPM["pm"] ?? []).map { $0.lowercased() })
        self.is24Hour = grammar.grammar.is24Hour

        // -- stripping tables, built once (VIK-012) -------------------------
        //
        // Each of these is one alternation in `entities.py::_en_strip_patterns`.
        // Read that function alongside `strippingDateTime`; the tables and the
        // order are the whole contract.
        let strip = grammar.strip
        var units: [String] = []
        for (_, synonyms) in grammar.relativeUnits { units.append(contentsOf: synonyms) }
        self.stripUnits = Self.longestFirstUnique(units)
        self.stripAmPM = Self.longestFirstUnique(
            (grammar.amPM["am"] ?? []) + (grammar.amPM["pm"] ?? []))
        self.stripAtBy = Self.longestFirstUnique(strip["at_by"] ?? [])
        self.stripRecurrence = Self.longestFirstUnique(strip["recurrence"] ?? [])
        self.stripThe = Self.longestFirstUnique(strip["the"] ?? [])
        self.stripConnectors = Self.longestFirstUnique(strip["connectors"] ?? [])
        self.clockHourMarkers = Self.longestFirstUnique(grammar.clockHourMarkers)

        // Only today/tomorrow/tonight. NOT day_after_tomorrow, next_week or
        // yesterday: the reference strips "tomorrow" out of "the day after
        // tomorrow" and leaves "the day after", and removes "next" from "next
        // week" as a connector while keeping "week". Matching that exactly
        // matters more than the tidier-looking alternative.
        var anchors: [String] = []
        for role in ["today", "tomorrow", "tonight"] {
            anchors.append(contentsOf: grammar.dayAnchors[role] ?? [])
        }
        self.stripAnchors = Self.longestFirstUnique(anchors)

        // Midnight is excluded. The reference filters it out of the period
        // alternation, so "take pills at midnight" keeps "midnight" in the
        // topic while "at" goes. Removing it here would read as tidier and be a
        // silent behaviour change.
        var periods: [String] = []
        for (role, entry) in grammar.timeOfDay where role != "midnight" {
            periods.append(contentsOf: entry.names)
        }
        self.stripPeriods = Self.longestFirstUnique(periods)

        // Weekday synonyms, minus the abbreviations.
        //
        // The reference strips a fixed list of full weekday names with an
        // optional plural `s`. A pack carries BOTH forms — "monday" and "mon",
        // "saturday" and "sat" — and stripping the short ones wrecks ordinary
        // topics: "buy sun cream" becomes "buy cream", "sat down" becomes
        // "down". The grammar has no field marking which synonyms are safe to
        // remove from free text, so length stands in for it (VIK-025). For
        // English this yields exactly the reference's seven names.
        var weekdays: [String] = []
        for (_, synonyms) in grammar.weekdays {
            for synonym in synonyms where synonym.count >= Self.weekdayStripMinimumLength {
                weekdays.append(synonym)
            }
        }
        self.stripWeekdays = Self.longestFirstUnique(weekdays)
    }

    /// Below this, a weekday synonym is treated as an abbreviation and is not
    /// stripped from a free-text topic. See `stripWeekdays`.
    static let weekdayStripMinimumLength = 4

    private static func longestFirstUnique(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for raw in phrases {
            let phrase = raw.lowercased()
            guard !phrase.isEmpty, seen.insert(phrase).inserted else { continue }
            unique.append(phrase)
        }
        return unique.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
        }
    }

    // MARK: - Entry point

    func parse(_ text: String, now: Date = Date()) -> Match? {
        var t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // 1 — relative durations, before any normalisation.
        if let hit = relativeDuration(in: t, now: now) { return hit }

        // 2 — an explicitly past day is a no-match, not a date in the past.
        for phrase in yesterdayPhrases where Self.containsWord(phrase, in: t) { return nil }

        // 3 — ordinals BEFORE cardinals. The cardinal pass would consume the
        // leading component of a compound ordinal ("twenty fifth" → "20 fifth")
        // and strand the rest.
        t = normalizeOrdinals(t)
        t = normalizeCardinals(t)

        // Retry: step 1 needs a digit, so a spelled-out duration only becomes
        // matchable now.
        if let hit = relativeDuration(in: t, now: now) { return hit }

        // 4 — day.
        var baseDay = now
        var dayExplicit = false
        var consumedAnchor = false

        // Anchors and weekdays are NOT blanked. "tonight" is deliberately both a
        // day anchor (offset 0) and a period name (evening → 18:00); blanking it
        // here would leave the period lookup with nothing and the utterance
        // would resolve to a bare day at the 09:00 default instead of 18:00.
        for anchor in anchorPhrases {
            guard Self.containsWord(anchor.phrase, in: t),
                  let offset = Self.anchorOffsets[anchor.value] else { continue }
            baseDay = calendar.date(byAdding: .day, value: offset, to: now) ?? now
            dayExplicit = true
            consumedAnchor = true
            break
        }

        if !consumedAnchor {
            let sorted = weekdayIndex.sorted { lhs, rhs in
                lhs.key.count == rhs.key.count ? lhs.key < rhs.key : lhs.key.count > rhs.key.count
            }
            for (synonym, index) in sorted {
                guard Self.containsWord(synonym, in: t) else { continue }
                // Monday-based grammar index → Calendar's Sunday-based weekday.
                let target = (index + 1) % 7 + 1
                let current = calendar.component(.weekday, from: now)
                var ahead = (target - current + 7) % 7
                if ahead == 0 { ahead = 7 }   // "friday" on a Friday means next Friday
                baseDay = calendar.date(byAdding: .day, value: ahead, to: now) ?? now
                dayExplicit = true
                consumedAnchor = true
                break
            }
        }

        // 4a — an explicit calendar date.
        if !consumedAnchor, let dated = absoluteDate(in: t, now: now) {
            baseDay = dated.day
            dayExplicit = true
            t = Self.blank(t, dated.range)
        }

        // 4b — period hint ("morning", "tonight").
        var period: String?
        for candidate in periodPhrases where Self.containsWord(candidate.phrase, in: t) {
            period = candidate.value
            break
        }

        // 5/6 — the clock.
        let clock = time(in: t, period: period)

        // 7 — assemble.
        return assemble(clock: clock, period: period, baseDay: baseDay,
                        dayExplicit: dayExplicit, now: now)
    }

    // MARK: - 1. Relative durations

    private func relativeDuration(in t: String, now: Date) -> Match? {
        let inFor = Self.alternation(markersIn + markersFor)
        let unitAlt = Self.alternation(Array(unitIndex.keys))
        guard !inFor.isEmpty, !unitAlt.isEmpty else { return nil }

        // "in 10 minutes" / "for 10 minutes"
        if let m = Self.firstMatch(#"\b(?:\#(inFor))\s+(\d+)\s*(\#(unitAlt))\b"#, in: t),
           let n = Int(m.groups[1]), let canonical = unitIndex[m.groups[2]],
           let date = add(n, canonical, to: now) {
            return Match(date: date, span: m.matched, timeExplicit: true, dayExplicit: false)
        }
        // "in a minute"
        let inAlt = Self.alternation(markersIn)
        let articleAlt = Self.alternation(articles)
        if !inAlt.isEmpty, !articleAlt.isEmpty,
           let m = Self.firstMatch(#"\b(?:\#(inAlt))\s+(?:\#(articleAlt))\s+(\#(unitAlt))\b"#, in: t),
           let canonical = unitIndex[m.groups[1]], let date = add(1, canonical, to: now) {
            return Match(date: date, span: m.matched, timeExplicit: true, dayExplicit: false)
        }
        // "in a few minutes"
        for quantifier in quantifiers {
            let qAlt = Self.alternation(quantifier.phrases)
            guard !qAlt.isEmpty, !inAlt.isEmpty else { continue }
            if let m = Self.firstMatch(#"\b(?:\#(inAlt))\s+(?:\#(qAlt))\s*(\#(unitAlt))\b"#, in: t),
               let canonical = unitIndex[m.groups[1]],
               let date = add(quantifier.n, canonical, to: now) {
                return Match(date: date, span: m.matched, timeExplicit: true, dayExplicit: false)
            }
        }
        // "in half an hour"
        let halfAlt = Self.alternation(idioms["half_an_hour"] ?? [])
        if !halfAlt.isEmpty, !inAlt.isEmpty,
           let m = Self.firstMatch(#"\b(?:\#(inAlt))\s+(?:\#(halfAlt))\b"#, in: t),
           let date = calendar.date(byAdding: .minute, value: 30, to: now) {
            return Match(date: date, span: m.matched, timeExplicit: true, dayExplicit: false)
        }
        return nil
    }

    private func add(_ n: Int, _ unit: String, to date: Date) -> Date? {
        switch unit {
        case "minute": return calendar.date(byAdding: .minute, value: n, to: date)
        case "hour":   return calendar.date(byAdding: .hour, value: n, to: date)
        case "day":    return calendar.date(byAdding: .day, value: n, to: date)
        case "week":   return calendar.date(byAdding: .day, value: n * 7, to: date)
        case "month":  return calendar.date(byAdding: .month, value: n, to: date)
        case "year":   return calendar.date(byAdding: .year, value: n, to: date)
        default:       return nil
        }
    }

    // MARK: - 3. Normalisation

    /// Spelled-out ordinals → digits, but ONLY in a date context.
    ///
    /// A bare ordinal is ambiguous: without the gate "wait a second" becomes
    /// "wait a 2nd" and the clock parser claims the 2. Context is an
    /// `ordinal_context` marker or an adjacent month, both from the pack.
    private func normalizeOrdinals(_ text: String) -> String {
        guard !ordinalPhrases.isEmpty else { return text }
        var contexts = ordinalContext
        contexts.append(contentsOf: monthIndex.keys)
        guard !contexts.isEmpty else { return text }
        let contextAlt = Self.alternation(contexts)

        var result = text
        for entry in ordinalPhrases {
            let escaped = NSRegularExpression.escapedPattern(for: entry.phrase)
            // Emit the ORDINAL MARKER, not a bare digit. The marker is what
            // later distinguishes a day-of-month from a clock hour: "the 25th"
            // must stay recognisable as a date, and rewriting it to "the 25"
            // strips the only signal the bare-day branch has, so it silently
            // stops resolving. A trailing dot is the language-neutral form
            // (German writes "25." natively); the date patterns accept it
            // alongside the English suffixes.
            let digits = "\(entry.value)\(Self.ordinalMarker)"
            result = Self.replace(#"\b(\#(contextAlt))\s+\#(escaped)\b"#,
                                  in: result) { "\($0.groups[1]) \(digits)" }
            result = Self.replace(#"\b\#(escaped)\s+(\#(contextAlt))\b"#,
                                  in: result) { "\(digits) \($0.groups[1])" }
        }
        return result
    }

    /// Written after a normalised ordinal so the date patterns can still see it.
    private static let ordinalMarker = "."
    /// Anything that marks a number as an ordinal day: the English suffixes, or
    /// the dot `normalizeOrdinals` writes.
    private static let ordinalSuffixPattern = #"(?:st|nd|rd|th|\.)"#

    /// Spelled-out cardinals → digits, longest phrase first.
    private func normalizeCardinals(_ text: String) -> String {
        var result = text
        let sorted = numberIndex.sorted { lhs, rhs in
            lhs.key.count == rhs.key.count ? lhs.key < rhs.key : lhs.key.count > rhs.key.count
        }
        for (word, value) in sorted {
            let escaped = NSRegularExpression.escapedPattern(for: word)
            result = Self.replace(#"\b\#(escaped)\b"#, in: result) { _ in "\(value)" }
        }
        return result
    }

    // MARK: - 4a. Absolute date

    private func absoluteDate(in t: String, now: Date) -> (day: Date, range: NSRange)? {
        let monthAlt = Self.alternation(Array(monthIndex.keys))
        let contextAlt = Self.alternation(ordinalContext)
        let gap = contextAlt.isEmpty ? #"\s+"# : #"(?:\s+(?:\#(contextAlt)))?\s+"#
        let ordinalSuffix = Self.ordinalSuffixPattern + "?"

        if !monthAlt.isEmpty {
            // "june 5" / "june the 5th"
            if let m = Self.firstMatch(#"\b(\#(monthAlt))\#(gap)(\d{1,2})\#(ordinalSuffix)\b"#, in: t),
               let month = monthIndex[m.groups[1]], let day = Int(m.groups[2]),
               let date = calendarDate(month: month, day: day, now: now) {
                return (date, m.range)
            }
            // "5 june" / "the 5th of june"
            if let m = Self.firstMatch(#"\b(\d{1,2})\#(ordinalSuffix)\#(gap)(\#(monthAlt))\b"#, in: t),
               let day = Int(m.groups[1]), let month = monthIndex[m.groups[2]],
               let date = calendarDate(month: month, day: day, now: now) {
                return (date, m.range)
            }
            // A month WAS named but the date was impossible ("31 february").
            // Do not fall through to the bare-day branch and silently resolve it
            // against the current month — the user named a month; honour it or fail.
            if Self.firstMatch(#"\b\#(monthAlt)\b"#, in: t) != nil { return nil }
        }

        // Bare day-of-month. Requires a context marker AND an ordinal suffix —
        // a naked digit is a clock hour on this path, never a date.
        guard !contextAlt.isEmpty,
              let m = Self.firstMatch(
                #"\b(?:\#(contextAlt))\s+(\d{1,2})\#(Self.ordinalSuffixPattern)"#, in: t),
              let day = Int(m.groups[1]),
              let date = calendarDate(month: nil, day: day, now: now)
        else { return nil }
        return (date, m.range)
    }

    /// Resolve a day (and optional month) to the next such date at 09:00.
    private func calendarDate(month: Int?, day: Int, now: Date) -> Date? {
        guard (1...31).contains(day) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.month = month ?? components.month
        components.day = day
        components.hour = 9; components.minute = 0; components.second = 0

        guard var candidate = calendar.date(from: components),
              calendar.component(.day, from: candidate) == day   // rejects "31 february"
        else { return nil }

        if calendar.startOfDay(for: candidate) < calendar.startOfDay(for: now) {
            // Already past: next year if a month was named, else next month.
            let unit: Calendar.Component = month == nil ? .month : .year
            guard let next = calendar.date(byAdding: unit, value: 1, to: candidate),
                  calendar.component(.day, from: next) == day else { return nil }
            candidate = next
        }
        return candidate
    }

    // MARK: - 5/6. Clock

    private struct Clock { var hour: Int; var minute: Int; var span: String; var explicitAMPM: Bool }

    private func time(in t: String, period: String?) -> Clock? {
        // Idioms first — "half past 9" must not be read as a bare "9".
        if let alt = idiomAlternation("half_past"),
           let m = Self.firstMatch(#"\b(?:\#(alt))\s+(\d{1,2})\b"#, in: t),
           let h = Int(m.groups[1]) {
            return Clock(hour: h, minute: 30, span: m.matched, explicitAMPM: false)
        }
        if let alt = idiomAlternation("quarter_past"),
           let m = Self.firstMatch(#"\b(?:\#(alt))\s+(\d{1,2})\b"#, in: t),
           let h = Int(m.groups[1]) {
            return Clock(hour: h, minute: 15, span: m.matched, explicitAMPM: false)
        }
        if let alt = idiomAlternation("quarter_to"),
           let m = Self.firstMatch(#"\b(?:\#(alt))\s+(\d{1,2})\b"#, in: t),
           let h = Int(m.groups[1]), (1...12).contains(h) {
            return Clock(hour: h > 1 ? h - 1 : 12, minute: 45, span: m.matched, explicitAMPM: false)
        }
        // "20 past 9"
        if let alt = idiomAlternation("past"),
           let m = Self.firstMatch(#"\b(\d{1,2})\s+(?:\#(alt))\s+(\d{1,2})\b"#, in: t),
           let mm = Int(m.groups[1]), let hh = Int(m.groups[2]),
           (0...59).contains(mm), (1...12).contains(hh) {
            return Clock(hour: hh, minute: mm, span: m.matched, explicitAMPM: false)
        }
        // "10 to 3" = 2:50
        if let alt = idiomAlternation("to"),
           let m = Self.firstMatch(#"\b(\d{1,2})\s+(?:\#(alt))\s+(\d{1,2})\b"#, in: t),
           let mins = Int(m.groups[1]), let h = Int(m.groups[2]),
           (1...59).contains(mins), (1...12).contains(h) {
            return Clock(hour: h > 1 ? h - 1 : 12, minute: 60 - mins,
                         span: m.matched, explicitAMPM: false)
        }

        // "9am", "9:30 pm"
        let ampmAlt = Self.alternation(Array(amForms) + Array(pmForms))
        if !ampmAlt.isEmpty,
           let m = Self.firstMatch(#"\b(\d{1,2})(?::(\d{2}))?\s*(\#(ampmAlt))\b"#, in: t),
           let raw = Int(m.groups[1]) {
            let isPM = pmForms.contains(m.groups[3])
            return Clock(hour: raw % 12 + (isPM ? 12 : 0),
                         minute: Int(m.groups[2]) ?? 0,
                         span: m.matched, explicitAMPM: true)
        }
        // "9:30". NOT explicitAMPM — a colon gives minutes, not a half of the
        // clock, so "9:30" at 10:00 still has to resolve to 21:30 rather than
        // 09:30 tomorrow. Marking it explicit here shifts it by a day.
        if let m = Self.firstMatch(#"\b(\d{1,2}):(\d{2})\b"#, in: t),
           let h = Int(m.groups[1]), let mm = Int(m.groups[2]) {
            return Clock(hour: h, minute: mm, span: m.matched, explicitAMPM: false)
        }
        // "15h30" / "9h" — continental written clock. Same reasoning: a
        // 24-hour-looking hour is caught by the 1...12 guard downstream.
        if let m = Self.firstMatch(#"\b(\d{1,2})h(\d{2})?\b"#, in: t), let h = Int(m.groups[1]) {
            return Clock(hour: h, minute: Int(m.groups[2]) ?? 0,
                         span: m.matched, explicitAMPM: false)
        }
        // "15.30" — Danish/German decimal. Minute block 00-59 avoids decimals.
        if let m = Self.firstMatch(#"\b(\d{1,2})\.(\d{2})\b"#, in: t),
           let h = Int(m.groups[1]), let mm = Int(m.groups[2]), (0...59).contains(mm) {
            return Clock(hour: h, minute: mm, span: m.matched, explicitAMPM: false)
        }
        // "at 9 30" then "at 9", both driven by the pack's `at` marker.
        let atAlt = Self.alternation((idioms["at"] ?? []) + markersAt)
        if !atAlt.isEmpty {
            if let m = Self.firstMatch(#"\b(?:\#(atAlt))\s+(\d{1,2})\s+(\d{2})\b"#, in: t),
               let h = Int(m.groups[1]), let mm = Int(m.groups[2]), (0...59).contains(mm) {
                return Clock(hour: h, minute: mm, span: m.matched, explicitAMPM: false)
            }
            if let m = Self.firstMatch(#"\b(?:\#(atAlt))\s+(\d{1,2})\b"#, in: t),
               let h = Int(m.groups[1]) {
                return Clock(hour: h, minute: 0, span: m.matched, explicitAMPM: false)
            }
        }
        // A bare number as the ENTIRE input — a slot answer like "9".
        if let m = Self.firstMatch(#"^(\d{1,2})\s*$"#, in: t), let h = Int(m.groups[1]) {
            return Clock(hour: h, minute: 0, span: m.matched, explicitAMPM: false)
        }
        // "9 30" without a colon (ASR output).
        if let m = Self.firstMatch(#"\b(\d{1,2})\s+(\d{2})\b"#, in: t),
           let h = Int(m.groups[1]), let mm = Int(m.groups[2]), (0...59).contains(mm) {
            return Clock(hour: h, minute: mm, span: m.matched, explicitAMPM: false)
        }
        // A digit with a period word: "9 tonight". Runs before the named-only
        // fallback so the digit beats the period's default hour.
        if let period, periodHours[period] != nil,
           let m = Self.firstMatch(#"\b(\d{1,2})\b"#, in: t),
           let h = Int(m.groups[1]), (1...12).contains(h) {
            return Clock(hour: h, minute: 0, span: m.matched, explicitAMPM: false)
        }
        // Named time only: "in the morning". Left non-explicit so the period
        // hint still drives disambiguation — "in the morning" at 10:00 must roll
        // to 08:00 TOMORROW, not resolve to a time already past today.
        if let period, let h = periodHours[period] {
            return Clock(hour: h, minute: 0, span: period, explicitAMPM: false)
        }
        return nil
    }

    private func idiomAlternation(_ key: String) -> String? {
        let alt = Self.alternation(idioms[key] ?? [])
        return alt.isEmpty ? nil : alt
    }

    // MARK: - 7. Assemble

    private func assemble(clock: Clock?, period: String?, baseDay: Date,
                          dayExplicit: Bool, now: Date) -> Match? {
        guard let clock else {
            guard dayExplicit else { return nil }
            // A day with no time. Default to 09:00 and report timeExplicit
            // false so the dialog engine can ask for the hour while keeping
            // the day the user already gave.
            guard let date = at(hour: 9, minute: 0, on: baseDay) else { return nil }
            if calendar.startOfDay(for: date) < calendar.startOfDay(for: now) { return nil }
            return Match(date: date, span: "", timeExplicit: false, dayExplicit: true)
        }
        guard (0...59).contains(clock.minute) else { return nil }

        let resolved: Date?
        if (1...12).contains(clock.hour) && !clock.explicitAMPM && !is24Hour {
            // Ambiguous 12-hour input — use the period hint to pick a side.
            resolved = pickFutureHour(clock.hour, clock.minute, on: baseDay, now: now, period: period)
        } else {
            guard (0...23).contains(clock.hour) else { return nil }
            var candidate = at(hour: clock.hour, minute: clock.minute, on: baseDay)
            if !dayExplicit, let c = candidate, c <= now {
                candidate = calendar.date(byAdding: .day, value: 1, to: c)
            }
            resolved = candidate
        }
        guard let date = resolved else { return nil }
        if dayExplicit, calendar.startOfDay(for: baseDay) < calendar.startOfDay(for: now) {
            return nil
        }
        return Match(date: date, span: clock.span, timeExplicit: true, dayExplicit: dayExplicit)
    }

    /// A 1–12 hour with no am/pm: resolve to a 24-hour time.
    ///
    /// Mirrors `_pick_future_hour`. The middle branch is a product decision, not
    /// arithmetic: with no period hint, hours 1–6 are read as PM because nobody
    /// sets a 3am reminder. Hours 7–12 try AM first. Getting this wrong shifts
    /// reminders by twelve hours, so the branch order is not free to tidy.
    private func pickFutureHour(_ hour: Int, _ minute: Int, on day: Date,
                                now: Date, period: String?) -> Date? {
        let h24: Int
        switch period {
        case "am", "morning":
            h24 = hour % 12                       // 12am → 0
        case "pm", "afternoon", "evening", "night":
            h24 = hour % 12 + 12                  // 12pm → 12
        default:
            h24 = (1...6).contains(hour) ? hour + 12 : hour
        }
        guard var candidate = at(hour: h24, minute: minute, on: day) else { return nil }

        // Past, today, and no hint to go on — try the other half of the clock.
        if candidate <= now,
           calendar.isDate(day, inSameDayAs: now),
           period == nil {
            let alternative = h24 < 12 ? h24 + 12 : h24 - 12
            if (0...23).contains(alternative),
               let other = at(hour: alternative, minute: minute, on: day),
               other > now {
                return other
            }
        }
        if candidate <= now {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private func at(hour: Int, minute: Int, on day: Date) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour; components.minute = minute; components.second = 0
        return calendar.date(from: components)
    }

    // MARK: - Topic stripping

    /// Remove every date/time fragment so what remains can be used as an open
    /// slot's free-text topic: "remind me to drink water at 6pm" → "drink water".
    ///
    /// Replaces `EntityExtractor.stripDateTime`, which had TWO implementations —
    /// a hardcoded English `timePatterns` array (weekday names, "tomorrow",
    /// "morning", "every|each", "at|on|by|this|next") and a lexicon-driven one
    /// for fr/de/da. English never reached the lexicon path, so the English
    /// vocabulary was invisible to any pack. There is one path here.
    ///
    /// The English regex array maps cleanly onto pack data: its `every|each`
    /// clause is `strip.recurrence`, its `at|on|by|this|next` clause is
    /// `strip.connectors`, and the rest are the day/month/period tables.
    ///
    /// Cosmetic, not semantic — this only decides how tidy a topic string reads,
    /// so an over- or under-strip degrades wording, never slot resolution.
    ///
    /// Word boundaries are explicit lookarounds rather than `\b`: ICU's `\b`
    /// treats an accented letter as a non-word character, so `\bmardi\b` matches
    /// inside "démardi". Carried over from the lexicon path for that reason.
    func strippingDateTime(_ text: String) -> String {
        var t = text

        func strip(_ pattern: String) {
            t = t.replacingOccurrences(of: pattern, with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }

        // 1 — "<in|for> N <unit>". Before the bare-digit passes, or the number
        //     is claimed as a clock hour and the unit is left stranded.
        if let markers = Self.alternationOrNil(markersIn + markersFor),
           let units = Self.alternationOrNil(stripUnits) {
            strip(#"\b(?:\#(markers))\s+\d+\s*(?:\#(units))\b"#)
        }

        // 2 — a digit with an am/pm form, removed together. Stripping "pm"
        //     alone leaves a bare "9" in the topic.
        if let ampm = Self.alternationOrNil(stripAmPM) {
            strip(#"\b\d{1,2}(?::\d{2})?\s*(?:\#(ampm))\b"#)
        }

        // 3 — a written clock.
        strip(#"\b\d{1,2}:\d{2}\b"#)

        // 4 — "<at|by> 7", digit included. This is what `strip.at_by` is for,
        //     and it must run BEFORE step 9 removes "at"/"by" as bare
        //     connectors — otherwise the connector goes and the orphan digit
        //     stays, and "dinner at 7" becomes the topic "dinner 7".
        if let atBy = Self.alternationOrNil(stripAtBy) {
            strip(#"\b(?:\#(atBy))\s+\d{1,2}(?::\d{2})?\b"#)
        }

        // 5 — today / tomorrow / tonight.
        if let anchors = Self.alternationOrNil(stripAnchors) {
            strip(#"\b(?:\#(anchors))\b"#)
        }

        // 6 — weekdays, with an optional plural.
        if let weekdays = Self.alternationOrNil(stripWeekdays) {
            strip(#"\b(?:\#(weekdays))s?\b"#)
        }

        // 7 — recurrence takes the word it governs ("every morning").
        //
        //     `\w+`, not `\S+`. It runs AFTER weekdays, so "each saturday" has
        //     already lost its day and this matches nothing, leaving a bare
        //     "each" behind. That looks like a bug and is faithfully the
        //     reference's behaviour; the ordering is what produces it, and
        //     changing either half here diverges from the engine the model was
        //     trained against.
        if let recurrence = Self.alternationOrNil(stripRecurrence) {
            strip(#"\b(?:\#(recurrence))\s+\w+\b"#)
        }

        // 8 — a period, optionally with the "in the" that introduces it. The
        //     prefix is why `strip.the` exists; the article is never removed on
        //     its own.
        if let periods = Self.alternationOrNil(stripPeriods) {
            var prefix = ""
            if let inMarker = Self.alternationOrNil(markersIn),
               let the = Self.alternationOrNil(stripThe) {
                prefix = #"(?:(?:\#(inMarker))\s+(?:\#(the))\s+)?"#
            }
            strip(#"\b\#(prefix)(?:\#(periods))\b"#)
        }

        // 9 — leftover connectors.
        if let connectors = Self.alternationOrNil(stripConnectors) {
            strip(#"\b(?:\#(connectors))\b"#)
        }

        // 10 — spaced clock-hour forms ("18 h", "18 heures").
        //
        //      NOT in the reference's English path, which has no such pattern —
        //      but `clock_hour_markers` is empty for English, so this cannot
        //      fire there and parity is unaffected. It is here for the first
        //      24-hour pack, which will also need the continental written forms
        //      (`15h30`, `15.30`) that the reference handles on its other path.
        //      Deliberately not added yet: they would strip "5.50" out of an
        //      English topic today, for a language that does not exist yet.
        if let markers = Self.alternationOrNil(clockHourMarkers) {
            strip(#"\b\d{1,2}\s+(?:\#(markers))\b"#)
        }

        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
    }

    private static func alternationOrNil(_ phrases: [String]) -> String? {
        let alt = alternation(phrases)
        return alt.isEmpty ? nil : alt
    }

    // MARK: - Regex helpers

    private struct RegexMatch { let matched: String; let groups: [String]; let range: NSRange }

    private static func alternation(_ phrases: [String]) -> String {
        let sorted = phrases.filter { !$0.isEmpty }
            .sorted { lhs, rhs in lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count }
        guard !sorted.isEmpty else { return "" }
        return sorted.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        var groups: [String] = []
        for i in 0..<match.numberOfRanges {
            if let r = Range(match.range(at: i), in: text) { groups.append(String(text[r])) }
            else { groups.append("") }
        }
        return RegexMatch(matched: groups.first ?? "", groups: groups, range: match.range)
    }

    private static func replace(_ pattern: String, in text: String,
                                _ transform: (RegexMatch) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }
        var result = text
        // Back to front so earlier ranges stay valid.
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                if let r = Range(match.range(at: i), in: result) { groups.append(String(result[r])) }
                else { groups.append("") }
            }
            let m = RegexMatch(matched: String(result[range]), groups: groups, range: match.range)
            result.replaceSubrange(range, with: transform(m))
        }
        return result
    }

    private static func wordRange(of needle: String, in haystack: String) -> NSRange? {
        let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: needle))\b"#
        return firstMatch(pattern, in: haystack)?.range
    }

    private static func containsWord(_ needle: String, in haystack: String) -> Bool {
        wordRange(of: needle, in: haystack) != nil
    }

    /// Replace a matched span with spaces so a later pattern cannot re-read it —
    /// "june 5" must not also resolve as 05:00.
    private static func blank(_ text: String, _ range: NSRange) -> String {
        guard let r = Range(range, in: text) else { return text }
        var result = text
        result.replaceSubrange(r, with: String(repeating: " ", count: text.distance(
            from: r.lowerBound, to: r.upperBound)))
        return result
    }
}
