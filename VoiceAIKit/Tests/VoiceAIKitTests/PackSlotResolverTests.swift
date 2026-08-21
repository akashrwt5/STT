// PackSlotResolverTests.swift
// VoiceAIKitTests
//
// The seam `NLUEngine` now depends on. Three of these tests exist because the
// bug they cover is invisible at runtime: the slot simply never fills, the user
// is re-prompted, and nothing is logged.

import XCTest
@testable import VoiceAIKit

final class PackSlotResolverTests: XCTestCase {

    private var pack: ResolvedPack!
    private var resolver: PackSlotResolver!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pack = try PackTestSupport.loadPack()
        resolver = PackSlotResolver(pack: pack)
    }

    // MARK: - Entity classification

    /// VIK-018. The engine used to test `slot.entity == "sys.date-time"` — the
    /// root shim's HYPHENATED spelling. Every pack-driven slot carries the v3
    /// spelling `sys.date_time`, so under a pack that comparison was always
    /// false and date-time slots took the gazetteer path, which has no table for
    /// them and therefore never resolved.
    func testDateTimeEntityIsRecognisedUnderThePacksOwnSpelling() throws {
        // Plain loop, declared type — chained collection expressions over the
        // pack's nested types are what trips the Swift type-checker (VIK-005).
        var slotEntities: [String] = []
        for (_, workflow) in pack.intents {
            for slot in workflow.slots { slotEntities.append(slot.entity) }
        }
        let dateTimeSlot = try XCTUnwrap(
            slotEntities.first { $0.contains("date") },
            "the pack should have a date-time slot to test against")

        XCTAssertEqual(dateTimeSlot, "sys.date_time",
                       "v3 spells this with an underscore")
        XCTAssertNotEqual(dateTimeSlot, "sys.date-time",
                          "the hyphenated form is the root shim's, which we do not bind to")
        XCTAssertTrue(resolver.isDateTime(dateTimeSlot),
                      "asking the resolver must work regardless of which spelling the pack uses")
    }

    /// A dynamic entity has no value table. Under the old rule — "open means
    /// absent from `tables`" — that made `sys.date_time` report as OPEN, and
    /// `fillOpenTopics` then wrote the derived free-text topic ("buy milk")
    /// into the date-time slot, satisfying a required slot with a non-date.
    func testDynamicEntityIsNeverOpen() throws {
        XCTAssertFalse(resolver.isOpen("sys.date_time"),
                       "a date-time slot must not accept an arbitrary topic string")
        XCTAssertFalse(resolver.isOpen("sys.number_integer"))
    }

    func testClosedGazetteerEntityIsNotOpen() throws {
        XCTAssertFalse(resolver.isOpen("memory"),
                       "memory is a closed set — a free-text answer is not a memory")
        XCTAssertFalse(resolver.isOpen("recurrence"))
    }

    /// VIK-017, closed. `open` now reaches the resolver from the pack, with no
    /// host involvement — which is the whole point: the value that decides
    /// whether a slot accepts free text is language data, and language data does
    /// not belong in application code.
    func testOpenEntitiesComeFromThePack() throws {
        XCTAssertTrue(resolver.isOpen("remind"),
                      "remind is open in the pack — supplying it by hand is no longer needed")
        XCTAssertFalse(resolver.isOpen("memory"))
    }

    // MARK: - Extraction

    /// `isDirectAnswer` is the engine's distinction between "the user is
    /// answering this slot" and "scan the sentence for anything". Fuzzy matching
    /// belongs only to the first.
    func testFuzzyMatchingIsGatedByIsDirectAnswer() throws {
        let answered = resolver.extract("memory", from: "restraunt", isDirectAnswer: true)
        let scanned = resolver.extract("memory", from: "restraunt", isDirectAnswer: false)

        XCTAssertEqual(answered, "Restaurant", "a typo in a direct answer should still resolve")
        XCTAssertNil(scanned, "the same typo must not fill a slot during a speculative scan")
    }

    func testExactMatchResolvesEitherWay() throws {
        XCTAssertEqual(resolver.extract("memory", from: "switch to restaurant", isDirectAnswer: false),
                       "Restaurant")
        XCTAssertEqual(resolver.extract("memory", from: "switch to restaurant", isDirectAnswer: true),
                       "Restaurant")
    }

    // MARK: - Date-time

    /// The engine stores slot values as strings and parses the parked day back
    /// with `DateFormatter("yyyy-MM-dd'T'HH:mm")`. A format mismatch here would
    /// not throw — the parse returns nil, the parked day is dropped, and
    /// "tomorrow" silently becomes today.
    func testResolvedISORoundTripsThroughTheEnginesOwnFormatter() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 3, hour: 10, minute: 0)))

        let match = try XCTUnwrap(resolver.dateTime(in: "tomorrow at 3pm", now: now))
        XCTAssertTrue(match.timeExplicit)
        XCTAssertTrue(match.explicitDay)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let parsed = try XCTUnwrap(formatter.date(from: match.iso),
                                   "the engine must be able to parse what the resolver emits")

        XCTAssertEqual(calendar.component(.hour, from: parsed), 15)
        XCTAssertEqual(calendar.component(.day, from: parsed), 4)
    }

    func testDayWithoutATimeIsReportedAsSuch() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 3, hour: 10, minute: 0)))

        let match = try XCTUnwrap(resolver.dateTime(in: "tomorrow", now: now))
        XCTAssertFalse(match.timeExplicit, "the engine parks the day and prompts for the hour")
        XCTAssertTrue(match.explicitDay)
    }

    // MARK: - Topic stripping

    /// Parity with the reference is covered by `TopicDerivationParityTests`,
    /// against generated fixtures. What is asserted here is the property those
    /// fixtures exist to protect: the stripper removes date/time VOCABULARY,
    /// not English.
    ///
    /// Three near-misses, each of which a plausible "tidier" implementation
    /// gets wrong:
    ///  · `clock_idioms` carries the bare prepositions "to" and "past", so
    ///    feeding it to the phrase pass mangles "call to confirm".
    ///  · `strip.the` is only ever applied inside the "in the <period>" prefix;
    ///    applied on its own it rewrites what the user hears back.
    ///  · weekday synonyms include "sat" and "sun".
    func testStrippingRemovesDateVocabularyNotEnglish() throws {
        XCTAssertEqual(resolver.strippingDateTime("call to confirm"), "call to confirm")
        XCTAssertEqual(resolver.strippingDateTime("walk past the shop"), "walk past the shop")
        XCTAssertEqual(resolver.strippingDateTime("drink the green tea"), "drink the green tea")
        XCTAssertEqual(resolver.strippingDateTime("buy sun cream"), "buy sun cream",
                       "'sun' is a weekday abbreviation and must not be stripped")
        XCTAssertEqual(resolver.strippingDateTime("sat with mom"), "sat with mom")
    }

    /// `strip.at_by` removes the connector together with the digit it governs.
    /// Removing "at" as a bare connector instead leaves an orphan number in the
    /// reminder's name.
    func testConnectorAndItsDigitAreRemovedTogether() throws {
        XCTAssertEqual(resolver.strippingDateTime("dinner at 7"), "dinner")
        XCTAssertEqual(resolver.strippingDateTime("call john at 9:30"), "call john")
    }
}
