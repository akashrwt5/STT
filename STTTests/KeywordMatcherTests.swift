// KeywordMatcherTests.swift
// STTTests
//
// Word-boundary and negation coverage for Stage 1 keyword matching.
//
// The false-positive cases below were REAL misfires under the previous
// substring implementation — Stage 1 wins at 0.85 before Stage 2 runs, so
// each of these was an unrecoverable wrong command. They are pinned here so
// the substring behavior can never regress back in.

import XCTest
@testable import STT

final class KeywordMatcherTests: XCTestCase {

    private var matcher: KeywordMatcher!

    override func setUp() {
        super.setUp()
        matcher = KeywordMatcher()
    }

    private func intent(_ text: String) -> String? {
        matcher.match(text)?.label
    }

    // MARK: - Word-boundary false positives (previously misfired)

    func testCommuteDoesNotFireMute() {
        XCTAssertNil(intent("how long is my commute"))
    }

    func testMutedStatementsDoNotFireMute() {
        XCTAssertNil(intent("my phone is muted"))
        XCTAssertNil(intent("is the microphone muted"))
    }

    func testPastTenseTranscribedDoesNotFire() {
        XCTAssertNil(intent("he transcribed the meeting yesterday"))
    }

    func testTranslatedDoesNotFire() {
        XCTAssertNil(intent("what does translated mean"))
    }

    func testSwitchProgrammingDoesNotFireMemoryChange() {
        XCTAssertNil(intent("switch programming mode"))
    }

    // MARK: - Un-mute phrasing (previously fired Cmd.VolumeMute)

    func testOffMuteFiresUnmute() {
        XCTAssertEqual(intent("take me off mute"), "Cmd.VolumeUnmute")
        XCTAssertEqual(intent("take me off of mute"), "Cmd.VolumeUnmute")
    }

    func testUnmuteStillWins() {
        XCTAssertEqual(intent("unmute"), "Cmd.VolumeUnmute")
        XCTAssertEqual(intent("please unmute the tv"), "Cmd.VolumeUnmute")
    }

    // MARK: - Negation (word-boundary cues)

    func testExplicitNegationSuppressesMatch() {
        XCTAssertNil(intent("do not set a reminder"))
        XCTAssertNil(intent("don't translate this"))
        XCTAssertNil(intent("never mute the tv"))
    }

    func testCannotVariantsSuppressMatch() {
        // Previously negated only by substring accident ("not " inside "cannot ").
        XCTAssertNil(intent("cannot mute the tv"))
        XCTAssertNil(intent("can't mute this"))
        XCTAssertNil(intent("cant mute this"))
    }

    func testPianoIsNotANegation() {
        // Previously WRONGLY negated: "no " matched inside "piano ".
        XCTAssertEqual(intent("piano mute please"), "Cmd.VolumeMute")
    }

    func testNegationWindowIsLocal() {
        // Negation far earlier in the sentence (outside the 30-char window)
        // must not suppress a later command. Mirrors Python behavior.
        XCTAssertEqual(
            intent("no I meant something else entirely, just mute it"),
            "Cmd.VolumeMute"
        )
    }

    // MARK: - True positives must keep firing

    func testCoreCommandsStillMatch() {
        XCTAssertEqual(intent("volume up"), "Cmd.VolumeIncrease")
        XCTAssertEqual(intent("mute"), "Cmd.VolumeMute")
        XCTAssertEqual(intent("mute the tv please"), "Cmd.VolumeMute")
        XCTAssertEqual(intent("louder please"), "Cmd.VolumeIncrease")
        XCTAssertEqual(intent("transcribe this conversation"), "Cmd.TranscribeStart")
        XCTAssertEqual(intent("set a reminder to take pills"), "reminders.add")
        XCTAssertEqual(intent("don't let me forget the keys"), "reminders.add")
        XCTAssertEqual(intent("where is my phone"), "Cmd.FindMyPhone")
        XCTAssertEqual(intent("check battery"), "Cmd.BatteryLevel")
        XCTAssertEqual(intent("switch program"), "Cmd.MemoryChange")
        XCTAssertEqual(intent("send a message"), "Cmd.SendMessage")
    }

    func testRuleOrderSpecificBeforeGeneral() {
        // "set a reminder" and "remind me" must resolve to reminders.add either way;
        // "reminder complete" must not be shadowed by reminders.add rules.
        XCTAssertEqual(intent("mark reminder done"), "reminders.complete")
    }

    // MARK: - ASR artifacts

    func testTrailingPunctuationStillMatches() {
        XCTAssertEqual(intent("mute."), "Cmd.VolumeMute")
        XCTAssertEqual(intent("volume up!"), "Cmd.VolumeIncrease")
    }

    func testCollapsedAndDoubledWhitespace() {
        XCTAssertEqual(intent("volume  up"), "Cmd.VolumeIncrease")
        XCTAssertEqual(intent("  mute  "), "Cmd.VolumeMute")
    }

    func testCaseInsensitivity() {
        XCTAssertEqual(intent("MUTE"), "Cmd.VolumeMute")
        XCTAssertEqual(intent("Volume Up"), "Cmd.VolumeIncrease")
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertNil(intent(""))
        XCTAssertNil(intent("   "))
    }

    // MARK: - Confidence contract

    func testContainsConfidenceIs085() {
        let result = matcher.match("mute the tv")
        XCTAssertEqual(result?.confidence, 0.85)
    }
}
