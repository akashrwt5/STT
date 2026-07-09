// NLULexicon.swift
// STT
//
// Language data decoded from nlu_lexicon.<lang>.json in the Localization/ bundle.
//   Phase 0: the three NLUEngine word-lists (uncertain / no_idioms / carrier_phrases).
//   Phase 2: the full datetime grammar consumed by EntityExtractor (weekdays,
//            months, numbers, periods, relative markers, decimal-hour idioms).
// Decoding is tolerant: every field defaults to empty/neutral so a partial or
// older overlay still yields a usable struct (graceful degradation, never a throw).

import Foundation

public struct NLULexicon: Decodable, Sendable {

    // MARK: Phase 0 word-lists
    public let uncertain: [String]
    public let noIdioms: [String]
    public let carrierPhrases: [String]

    // MARK: Phase 2 datetime grammar

    /// One decimal-hour idiom. `hour != nil` → absolute time (midi=12, minuit=0).
    /// `minutes >= 0` → "past the named hour" (et quart=+15). `minutes < 0` →
    /// "to the named hour" / "half" counting down (halb/halv=-30, moins le quart=-15).
    /// Tolerates either an object `{phrase,minutes,hour}` or a bare string phrase.
    public struct DecimalHourIdiom: Decodable, Sendable {
        public let phrase: String
        public let minutes: Int?
        public let hour: Int?

        enum CodingKeys: String, CodingKey { case phrase, minutes, hour }

        public init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                phrase = s; minutes = nil; hour = nil; return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            phrase  = (try? c.decode(String.self, forKey: .phrase)) ?? ""
            minutes = (try? c.decodeIfPresent(Int.self, forKey: .minutes)) ?? nil
            hour    = (try? c.decodeIfPresent(Int.self, forKey: .hour)) ?? nil
        }
    }

    public struct Grammar: Decodable, Sendable {
        public let timeFormat: String                  // "24h" or "12h"
        public let decimalHourIdioms: [DecimalHourIdiom]
        public let conjunction: String?                // hour-minute joiner: "Uhr", "og", "et"

        enum CodingKeys: String, CodingKey {
            case timeFormat = "time_format"
            case decimalHourIdioms = "decimal_hour_idioms"
            case conjunction
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            timeFormat        = (try? c.decodeIfPresent(String.self, forKey: .timeFormat)) ?? "24h"
            decimalHourIdioms = (try? c.decodeIfPresent([DecimalHourIdiom].self, forKey: .decimalHourIdioms)) ?? []
            conjunction       = (try? c.decodeIfPresent(String.self, forKey: .conjunction)) ?? nil
        }
    }

    public struct TimeOfDayEntry: Decodable, Sendable {
        public let names: [String]
        public let hour: Int
    }

    public let grammar: Grammar?
    public let weekdays:        [String: [String]]     // "Monday" → ["lundi","lun"]
    public let dayAnchors:      [String: [String]]     // "tomorrow" → ["demain"]
    public let months:          [String: [String]]
    public let timeOfDay:       [String: TimeOfDayEntry]
    public let numbers0to31:    [String: [String]]
    public let ordinals1to31:   [String: [String]]
    public let relativeUnits:   [String: [String]]
    public let relativeMarkers: [String: [String]]
    /// Spaced clock-hour suffixes: "18 h", "18 heures". Separate from relativeUnits.hour
    /// so duration words (Danish "timer", German "Stunden") are never misread as clock markers.
    /// Only languages that write "N h" / "N heures" as clock time set this key.
    public let clockHourMarkers: [String]

    enum CodingKeys: String, CodingKey {
        case uncertain
        case noIdioms = "no_idioms"
        case carrierPhrases = "carrier_phrases"
        case grammar, weekdays, months
        case dayAnchors = "day_anchors"
        case timeOfDay = "time_of_day"
        case numbers0to31 = "numbers_0_to_31"
        case ordinals1to31 = "ordinals_1_to_31"
        case relativeUnits = "relative_units"
        case relativeMarkers = "relative_markers"
        case clockHourMarkers = "clock_hour_markers"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uncertain      = (try? c.decodeIfPresent([String].self, forKey: .uncertain))      ?? []
        noIdioms       = (try? c.decodeIfPresent([String].self, forKey: .noIdioms))       ?? []
        carrierPhrases = (try? c.decodeIfPresent([String].self, forKey: .carrierPhrases)) ?? []
        grammar         = (try? c.decodeIfPresent(Grammar.self, forKey: .grammar)) ?? nil
        weekdays        = (try? c.decodeIfPresent([String: [String]].self, forKey: .weekdays)) ?? [:]
        dayAnchors      = (try? c.decodeIfPresent([String: [String]].self, forKey: .dayAnchors)) ?? [:]
        months          = (try? c.decodeIfPresent([String: [String]].self, forKey: .months)) ?? [:]
        timeOfDay       = (try? c.decodeIfPresent([String: TimeOfDayEntry].self, forKey: .timeOfDay)) ?? [:]
        numbers0to31    = (try? c.decodeIfPresent([String: [String]].self, forKey: .numbers0to31)) ?? [:]
        ordinals1to31   = (try? c.decodeIfPresent([String: [String]].self, forKey: .ordinals1to31)) ?? [:]
        relativeUnits   = (try? c.decodeIfPresent([String: [String]].self, forKey: .relativeUnits)) ?? [:]
        relativeMarkers = (try? c.decodeIfPresent([String: [String]].self, forKey: .relativeMarkers)) ?? [:]
        clockHourMarkers = (try? c.decodeIfPresent([String].self, forKey: .clockHourMarkers)) ?? []
    }
}
