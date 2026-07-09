// ExtractDateTimeMultilingualTests.swift
// STTTests
//
// Phase 2 parity gate (Swift side). Each row mirrors a line in
// IntentClassifier/tests/datetime_parity/nlu_datetime_parity_<lang>.csv and the
// Python pytest test_datetime_parity.py. Both platforms must agree on every row.
//
// Reference "now" is pinned to Tuesday 2026-06-30 00:00 (local) — the same
// instant the Python test uses. A midnight reference keeps every "today"
// time-of-day in the future so it is not rolled to tomorrow.
//
// PLATFORM NOTE: reads the Localization/*.json from Bundle.main like the
// LocalizationLoader does at runtime; app-hosted, macOS + Xcode host.

import XCTest
@testable import VoiceIntentKit

final class ExtractDateTimeMultilingualTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c
    }()

    private lazy var now: Date = {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 6; dc.day = 30; dc.hour = 0; dc.minute = 0; dc.second = 0
        return cal.date(from: dc)!   // Tuesday
    }()

    private func extractor(_ lang: String) -> EntityExtractor {
        EntityExtractor(entitiesURL: LocalizationLoader.entitiesURL(language: lang),
                        lexicon: LocalizationLoader.lexicon(language: lang))
    }

    // MARK: Fixture rows (identical to the golden CSVs)

    private typealias Row = (utterance: String, date: String, time: String)

    private let fr: [Row] = [
        ("demain à 15h30", "+1d", "15:30"),
        ("lundi matin", "next_monday", "08:00"),
        ("le 3 juillet", "july_3", "-"),
        ("dans 5 minutes", "+5min", "-"),
        ("à midi", "today", "12:00"),
        ("vendredi soir", "next_friday", "18:00"),
        ("dix heures et demie", "today", "10:30"),
        ("huit heures moins le quart", "today", "07:45"),
    ]
    private let de: [Row] = [
        ("morgen um 15 Uhr 30", "+1d", "15:30"),
        ("Montag früh", "next_monday", "08:00"),
        ("am 3. Juli", "july_3", "-"),
        ("in 5 Minuten", "+5min", "-"),
        ("halb drei", "today", "02:30"),
        ("halb sechs nachmittags", "today", "17:30"),
        ("Viertel nach drei", "today", "03:15"),
        ("Viertel vor drei", "today", "02:45"),
        ("dreiviertel drei", "today", "02:45"),
    ]
    private let da: [Row] = [
        ("i morgen klokken 15:30", "+1d", "15:30"),
        ("mandag morgen", "next_monday", "08:00"),
        ("den 3. juli", "july_3", "-"),
        ("om 5 minutter", "+5min", "-"),
        ("halv tre", "today", "02:30"),
        ("halv seks om aftenen", "today", "17:30"),
        ("kvart over to", "today", "02:15"),
        ("kvart i tre", "today", "02:45"),
    ]

    func testFrenchFixtures() { runFixtures("fr", fr) }
    func testGermanFixtures() { runFixtures("de", de) }
    func testDanishFixtures() { runFixtures("da", da) }

    private func runFixtures(_ lang: String, _ rows: [Row]) {
        let ex = extractor(lang)
        for row in rows {
            guard let match = ex.extractDateTime(row.utterance, now: now) else {
                XCTFail("[\(lang)] \(row.utterance): produced no datetime"); continue
            }
            guard let date = ISO8601MinuteParser.date(match.iso, cal: cal) else {
                XCTFail("[\(lang)] \(row.utterance): un-parseable iso \(match.iso)"); continue
            }
            XCTAssertTrue(dateMatches(row.date, date),
                          "[\(lang)] \(row.utterance): date \(date) != expected \(row.date)")
            if row.time != "-" {
                XCTAssertEqual(clock(date), row.time,
                               "[\(lang)] \(row.utterance): time \(clock(date)) != expected \(row.time)")
            }
        }
    }

    // MARK: Parser-trap assertions (the bugs the lexicon must NOT reintroduce)

    func testHalbCountsDown_notUp() {
        // "halb drei" / "halv tre" = 02:30 — NOT 03:30.
        XCTAssertEqual(clock(parse("de", "halb drei")), "02:30")
        XCTAssertEqual(clock(parse("da", "halv tre")), "02:30")
        // "huit heures moins le quart" = 07:45 — NOT 08:15.
        XCTAssertEqual(clock(parse("fr", "huit heures moins le quart")), "07:45")
        // German quarter idioms.
        XCTAssertEqual(clock(parse("de", "Viertel vor drei")), "02:45")
        XCTAssertEqual(clock(parse("de", "dreiviertel drei")), "02:45")
    }

    func test24hDisablesPMHeuristic() {
        // German 24h clock: "drei Uhr" = 03:00, NOT 15:00 (no 1-6 → PM remap).
        XCTAssertEqual(clock(parse("de", "drei Uhr")), "03:00")
    }

    func testEnglishPathUnchanged() {
        // No lexicon → byte-identical English parser still resolves a clock time.
        guard let m = EntityExtractor().extractDateTime("tomorrow at 3pm", now: now),
              let d = ISO8601MinuteParser.date(m.iso, cal: cal) else {
            return XCTFail("English path failed to parse")
        }
        XCTAssertEqual(clock(d), "15:00")
        XCTAssertTrue(dateMatches("+1d", d))
    }

    // MARK: Helpers

    private func parse(_ lang: String, _ utterance: String) -> Date {
        guard let m = extractor(lang).extractDateTime(utterance, now: now),
              let d = ISO8601MinuteParser.date(m.iso, cal: cal) else {
            XCTFail("[\(lang)] \(utterance): no datetime"); return now
        }
        return d
    }

    private func clock(_ date: Date) -> String {
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func dateMatches(_ token: String, _ date: Date) -> Bool {
        switch token {
        case "today":
            return cal.isDate(date, inSameDayAs: now)
        case "+1d":
            return cal.isDate(date, inSameDayAs: cal.date(byAdding: .day, value: 1, to: now)!)
        case "+5min":
            return abs(date.timeIntervalSince(cal.date(byAdding: .minute, value: 5, to: now)!)) < 90
        default:
            if token.hasPrefix("next_") {
                let target = weekdayIndex(String(token.dropFirst(5)))
                let nowWd = (cal.component(.weekday, from: now) + 5) % 7
                var ahead = ((target - nowWd) % 7 + 7) % 7
                if ahead == 0 { ahead = 7 }
                return cal.isDate(date, inSameDayAs: cal.date(byAdding: .day, value: ahead, to: now)!)
            }
            if let us = token.firstIndex(of: "_") {        // "july_3"
                let mon = monthIndex(String(token[..<us]))
                let day = Int(token[token.index(after: us)...]) ?? -1
                let c = cal.dateComponents([.month, .day], from: date)
                return c.month == mon && c.day == day
            }
            return false
        }
    }

    private func weekdayIndex(_ name: String) -> Int {
        ["monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
         "friday": 4, "saturday": 5, "sunday": 6][name.lowercased()] ?? -1
    }
    private func monthIndex(_ name: String) -> Int {
        ["january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
         "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12][name.lowercased()] ?? -1
    }
}

/// Parses the `yyyy-MM-dd'T'HH:mm` form EntityExtractor emits back into a Date in
/// the test calendar's zone (the parser writes local naive minutes).
private enum ISO8601MinuteParser {
    static func date(_ iso: String, cal: Calendar) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: iso)
    }
}
