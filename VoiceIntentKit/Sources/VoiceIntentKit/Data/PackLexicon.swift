// PackLexicon.swift
// VoiceIntentKit
//
// `lexicons/<lang>.json` — the language's words.
//
// THIS FILE REPLACES `NLULexicon`, WHICH CONTAINED THE WORST BUG IN THE PACKAGE.
// The old type expected `carrier_phrases`, `weekdays`, `months`,
// `numbers_0_to_31` at the top level; a pack ships `carriers` and a nested
// `datetime_grammar`. None of the names overlapped. Because every field decoded
// with `try? … ?? []`, feeding it a real pack produced an ALL-EMPTY struct, and
// the engine factory then substituted `NLUEngine.defaultUncertain` /
// `defaultNoIdioms` / `defaultCarriers` — hardcoded English. No throw, no log.
// You could ship a French pack and get English rules with green tests.
//
// So: strict decoding, no defaults, no fallbacks. If a language's words are not
// in the pack, that is an error the caller sees.

import Foundation

struct PackLexicon: Decodable, Sendable {

    let lang: String
    let affirmative: [String]
    let negative: [String]
    let negationCues: [String]
    /// Anchored regexes stripped to expose an open topic
    /// ("remind me to " → ""). Portable-subset patterns only.
    let carriers: [String]
    let leadingConnectors: [String]
    /// "don't" → "do not". 50 entries for English. The flattened root shim drops
    /// this table entirely.
    let contractions: [String: String]
    let datetime: DateTimeGrammar
    
    let fuzzyStopwords: [String]?
    let trailingFunctionWords: [String]?

    enum CodingKeys: String, CodingKey {
        case lang, affirmative, negative, carriers, contractions
        case negationCues = "negation_cues"
        case leadingConnectors = "leading_connectors"
        case datetime = "datetime_grammar"
        case fuzzyStopwords
        case trailingFunctionWords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lang = try c.decode(String.self, forKey: .lang)
        affirmative = try c.decode([String].self, forKey: .affirmative)
        negative = try c.decode([String].self, forKey: .negative)
        negationCues = try c.decode([String].self, forKey: .negationCues)
        carriers = try c.decode([String].self, forKey: .carriers)
        leadingConnectors = try c.decode([String].self, forKey: .leadingConnectors)
        contractions = try c.decodeIfPresent([String: String].self, forKey: .contractions) ?? [:]
        datetime = try c.decode(DateTimeGrammar.self, forKey: .datetime)
        fuzzyStopwords = try c.decodeIfPresent([String].self, forKey: .fuzzyStopwords)
        trailingFunctionWords = try c.decodeIfPresent([String].self, forKey: .trailingFunctionWords)
    }
}

// MARK: - datetime_grammar

/// Everything needed to resolve a date or time, as data.
///
/// The keys below `weekdays` were absent from packs until the compiler was
/// extended: without them non-English date parsing cannot work at all, and
/// English silently could not resolve month names or ordinals either.
///
/// Dictionary KEYS are canonical English role names — `"Monday"`, `"January"`,
/// `"25"`. They are identifiers, not vocabulary; the language's actual words are
/// in the value arrays. Do not lowercase or localise the keys.
struct DateTimeGrammar: Decodable, Sendable {

    // -- day and period anchors -------------------------------------------
    /// Role → phrases. Roles: today, tonight, tomorrow, day_after_tomorrow,
    /// next_week, yesterday.
    let dayAnchors: [String: [String]]
    /// "morning" → (names, default hour).
    let timeOfDay: [String: TimeOfDay]

    // -- calendar vocabulary ----------------------------------------------
    /// "Monday" → ["monday", "mon"].
    let weekdays: [String: [String]]
    /// "January" → ["january", "jan"].
    let months: [String: [String]]
    /// "21" → ["twenty one", "twenty-one"].
    let numbers: [String: [String]]
    /// "25" → ["twenty fifth", "25th", "twenty-fifth"].
    let ordinals: [String: [String]]
    /// Words marking an ordinal as a day-of-month rather than a quantity —
    /// English the/of, French le/du/de. Without a date context a bare ordinal
    /// must NOT be rewritten to a digit: "wait a second" would become "wait a
    /// 2nd" and the clock parser would claim it.
    let ordinalContext: [String]

    // -- clock -------------------------------------------------------------
    /// "in"/"for"/"at" → phrases.
    let relativeMarkers: [String: [String]]
    /// "minute" → ["minutes", "minute", "mins", "min"].
    let relativeUnits: [String: [String]]
    /// half_past, quarter_past, quarter_to, past, to, half_an_hour.
    let clockIdioms: [String: [String]]
    /// am/pm surface forms. Empty for 24-hour languages.
    let amPM: [String: [String]]
    /// Spaced clock-hour suffixes ("18 h", "18 heures"). Deliberately separate
    /// from `relativeUnits.hour` so duration words (German "Stunden", Danish
    /// "timer") are never read as clock markers. Empty for English.
    let clockHourMarkers: [String]
    /// Articles ("a", "an") used by "in a minute".
    let articles: [String]
    /// "a few" → 3, "a couple" → 2.
    let quantifiers: [String: Quantifier]
    /// Function words stripped when deriving a topic. Cosmetic only.
    let strip: [String: [String]]
    /// 12h/24h, hour-minute joiner, decimal-hour idioms.
    let grammar: Grammar

    enum CodingKeys: String, CodingKey {
        case weekdays, months, articles, quantifiers, strip, grammar
        case dayAnchors = "day_anchors"
        case timeOfDay = "time_of_day"
        case numbers = "numbers_0_to_31"
        case ordinals = "ordinals_1_to_31"
        case ordinalContext = "ordinal_context"
        case relativeMarkers = "relative_markers"
        case relativeUnits = "relative_units"
        case clockIdioms = "clock_idioms"
        case amPM = "am_pm"
        case clockHourMarkers = "clock_hour_markers"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Required: without these there is no date parsing worth the name.
        dayAnchors = try c.decode([String: [String]].self, forKey: .dayAnchors)
        timeOfDay = try c.decode([String: TimeOfDay].self, forKey: .timeOfDay)
        weekdays = try c.decode([String: [String]].self, forKey: .weekdays)
        months = try c.decode([String: [String]].self, forKey: .months)
        numbers = try c.decode([String: [String]].self, forKey: .numbers)
        ordinals = try c.decode([String: [String]].self, forKey: .ordinals)
        relativeMarkers = try c.decode([String: [String]].self, forKey: .relativeMarkers)
        relativeUnits = try c.decode([String: [String]].self, forKey: .relativeUnits)
        // Legitimately empty in some languages — absent means "not used here",
        // which is different from the required keys above.
        ordinalContext = try c.decodeIfPresent([String].self, forKey: .ordinalContext) ?? []
        clockIdioms = try c.decodeIfPresent([String: [String]].self, forKey: .clockIdioms) ?? [:]
        amPM = try c.decodeIfPresent([String: [String]].self, forKey: .amPM) ?? [:]
        clockHourMarkers = try c.decodeIfPresent([String].self, forKey: .clockHourMarkers) ?? []
        articles = try c.decodeIfPresent([String].self, forKey: .articles) ?? []
        quantifiers = try c.decodeIfPresent([String: Quantifier].self, forKey: .quantifiers) ?? [:]
        strip = try c.decodeIfPresent([String: [String]].self, forKey: .strip) ?? [:]
        grammar = try c.decodeIfPresent(Grammar.self, forKey: .grammar) ?? Grammar()
    }

    // MARK: Nested

    struct TimeOfDay: Decodable, Sendable {
        let names: [String]
        let hour: Int
    }

    struct Quantifier: Decodable, Sendable {
        let phrases: [String]
        let n: Int
    }

    struct Grammar: Decodable, Sendable {
        /// "12h" or "24h" — disambiguates a bare hour.
        let timeFormat: String
        /// Hour-minute joiner: German "Uhr", Danish "og".
        let conjunction: String?
        /// German "halb" (−30), French "midi" (hour 12). Empty for English,
        /// which expresses these through `clockIdioms`.
        let decimalHourIdioms: [DecimalHourIdiom]

        enum CodingKeys: String, CodingKey {
            case timeFormat = "time_format"
            case conjunction
            case decimalHourIdioms = "decimal_hour_idioms"
        }

        init() { timeFormat = "24h"; conjunction = nil; decimalHourIdioms = [] }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            timeFormat = try c.decodeIfPresent(String.self, forKey: .timeFormat) ?? "24h"
            conjunction = try c.decodeIfPresent(String.self, forKey: .conjunction)
            decimalHourIdioms = try c.decodeIfPresent([DecimalHourIdiom].self,
                                                      forKey: .decimalHourIdioms) ?? []
        }

        var is24Hour: Bool { timeFormat == "24h" }
    }

    /// `hour != nil` → absolute ("midi" = 12). `minutes >= 0` → past the named
    /// hour ("et quart" = +15). `minutes < 0` → counting down to it
    /// ("halb"/"halv" = −30).
    struct DecimalHourIdiom: Decodable, Sendable {
        let phrase: String
        let minutes: Int?
        let hour: Int?
    }
}

// MARK: - Lookups

/// A phrase paired with what it resolves to, ordered longest-first.
///
/// A named struct rather than a tuple: chained `flatMap`/`sorted`/`map` over
/// tuple literals is what makes Swift's type checker give up
/// ("unable to type-check this expression in reasonable time"). Every lookup
/// below is therefore a plain loop with declared types — slower to read, but it
/// compiles in milliseconds instead of failing.
struct PhraseMatch<Value: Sendable>: Sendable {
    let phrase: String
    let value: Value
}

extension DateTimeGrammar {

    // NOTE: these are computed, so each access rebuilds the table. That is fine
    // for setup but not per-utterance — a consumer on the hot path should build
    // them once and hold them.

    /// synonym → 0…6, Monday-based.
    var weekdayIndex: [String: Int] {
        Self.reverseIndex(weekdays, order: Self.weekdayOrder, offset: 0)
    }

    /// synonym → 1…12.
    var monthIndex: [String: Int] {
        Self.reverseIndex(months, order: Self.monthOrder, offset: 1)
    }

    /// synonym → integer, cardinals and ordinals together.
    var numberIndex: [String: Int] {
        var out: [String: Int] = [:]
        for (key, synonyms) in numbers {
            guard let n = Int(key) else { continue }
            for s in synonyms { out[s.lowercased()] = n }
        }
        for (key, synonyms) in ordinals {
            guard let n = Int(key) else { continue }
            for s in synonyms { out[s.lowercased()] = n }
        }
        return out
    }

    /// Ordinal synonyms, longest first so a compound wins over its parts
    /// ("twenty fifth" before "fifth").
    var ordinalPhrasesLongestFirst: [PhraseMatch<Int>] {
        var pairs: [PhraseMatch<Int>] = []
        for (key, synonyms) in ordinals {
            guard let n = Int(key) else { continue }
            for s in synonyms { pairs.append(PhraseMatch(phrase: s.lowercased(), value: n)) }
        }
        return Self.longestFirst(pairs)
    }

    /// Day-anchor phrases with their canonical role, longest first so
    /// "day after tomorrow" cannot be shadowed by "tomorrow".
    var dayAnchorPhrasesLongestFirst: [PhraseMatch<String>] {
        var pairs: [PhraseMatch<String>] = []
        for (role, phrases) in dayAnchors {
            for p in phrases { pairs.append(PhraseMatch(phrase: p.lowercased(), value: role)) }
        }
        return Self.longestFirst(pairs)
    }

    /// Ordinal-context markers, longest first.
    var ordinalContextLongestFirst: [String] {
        ordinalContext.map { $0.lowercased() }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
            }
    }

    /// synonym → canonical unit ("mins" → "minute").
    var unitIndex: [String: String] {
        var out: [String: String] = [:]
        for (canonical, synonyms) in relativeUnits {
            for s in synonyms { out[s.lowercased()] = canonical }
        }
        return out
    }

    // MARK: Helpers

    static let weekdayOrder: [String] = ["Monday", "Tuesday", "Wednesday", "Thursday",
                                         "Friday", "Saturday", "Sunday"]
    static let monthOrder: [String] = ["January", "February", "March", "April", "May", "June",
                                       "July", "August", "September", "October", "November",
                                       "December"]

    static func reverseIndex(_ table: [String: [String]],
                             order: [String],
                             offset: Int) -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, role) in order.enumerated() {
            guard let synonyms = table[role] else { continue }
            for s in synonyms { out[s.lowercased()] = i + offset }
        }
        return out
    }

    /// Longest phrase first, ties broken alphabetically so the order is stable
    /// across runs — matcher order decides which of two overlapping phrases wins.
    static func longestFirst<T: Sendable>(_ pairs: [PhraseMatch<T>]) -> [PhraseMatch<T>] {
        pairs.sorted { lhs, rhs in
            lhs.phrase.count == rhs.phrase.count
                ? lhs.phrase < rhs.phrase
                : lhs.phrase.count > rhs.phrase.count
        }
    }
}
