// EndpointDeciderTests.swift
// VoiceIntentKitTests
//
// The endpointing decision math, now that it lives in a pure, clock-free helper.
// These pin the exact windows and edge conditions that decide when a turn ends —
// the logic that a clip or a premature-endpoint regression would break — using
// explicit `now`/`lastChange` values instead of a real recognizer.

import XCTest
@testable import VoiceIntentKit

final class EndpointDeciderTests: XCTestCase {

    private func decider(maxUtterance: TimeInterval = 10.0) -> EndpointDecider {
        EndpointDecider(config: SilenceDetectionConfiguration(
            isEnabled: true,
            speechEndTimeout: 1.0,
            freeformAnswerTimeout: 1.5,
            incompleteAnswerTimeout: 2.5,
            maxUtteranceDuration: maxUtterance,
            maxUtteranceWordBoundaryGrace: 0.35,
            maxUtteranceHardCeiling: 3.0))
    }

    // MARK: - Window selection

    func testRequiredStabilityWindowPerVerdict() {
        let d = decider()
        XCTAssertEqual(d.requiredStabilityWindow(for: .complete), 1.0, accuracy: 0.0001)
        XCTAssertEqual(d.requiredStabilityWindow(for: .freeform), 1.5, accuracy: 0.0001)  // max(1.0, 1.5)
        XCTAssertEqual(d.requiredStabilityWindow(for: .incomplete), 2.5, accuracy: 0.0001)
    }

    // MARK: - Stability endpoint

    func testCompleteCommitsAtBaseWindow() {
        let d = decider()
        // Stable for exactly 1.0s → commits.
        XCTAssertTrue(d.shouldEndpointForStableTranscript(
            now: 100, lastChangeAt: 99.0, hasVolatileText: true,
            hasReceivedFinalResult: false, verdict: .complete))
        // Only 0.5s stable → not yet.
        XCTAssertFalse(d.shouldEndpointForStableTranscript(
            now: 100, lastChangeAt: 99.5, hasVolatileText: true,
            hasReceivedFinalResult: false, verdict: .complete))
    }

    func testIncompleteWaitsForExtendedWindow() {
        let d = decider()
        // 1.0s stable is enough for .complete but NOT for .incomplete (needs 2.5s).
        XCTAssertFalse(d.shouldEndpointForStableTranscript(
            now: 100, lastChangeAt: 99.0, hasVolatileText: true,
            hasReceivedFinalResult: false, verdict: .incomplete))
        // 2.5s stable → commits.
        XCTAssertTrue(d.shouldEndpointForStableTranscript(
            now: 100, lastChangeAt: 97.5, hasVolatileText: true,
            hasReceivedFinalResult: false, verdict: .incomplete))
    }

    func testFreeformUsesMediumWindow() {
        let d = decider()
        XCTAssertFalse(d.shouldEndpointForStableTranscript(
            now: 100, lastChangeAt: 98.6, hasVolatileText: true,          // 1.4s < 1.5s
            hasReceivedFinalResult: false, verdict: .freeform))
        XCTAssertTrue(d.shouldEndpointForStableTranscript(
            now: 100, lastChangeAt: 98.4, hasVolatileText: true,          // 1.6s ≥ 1.5s
            hasReceivedFinalResult: false, verdict: .freeform))
    }

    func testStabilityGuards() {
        let d = decider()
        // Already committed → never re-fire.
        XCTAssertFalse(d.shouldEndpointForStableTranscript(
            now: 100, lastChangeAt: 90, hasVolatileText: true,
            hasReceivedFinalResult: true, verdict: .complete))
        // Nobody spoke → nothing to endpoint.
        XCTAssertFalse(d.shouldEndpointForStableTranscript(
            now: 100, lastChangeAt: 90, hasVolatileText: false,
            hasReceivedFinalResult: false, verdict: .complete))
        // No transcript change recorded yet.
        XCTAssertFalse(d.shouldEndpointForStableTranscript(
            now: 100, lastChangeAt: 0, hasVolatileText: true,
            hasReceivedFinalResult: false, verdict: .complete))
    }

    // MARK: - Max-duration runaway guard

    func testMaxDurationDoesNotFireBeforeCap() {
        let d = decider(maxUtterance: 10)
        // Spoken 5s (< 10s cap).
        XCTAssertFalse(d.shouldEndpointForMaxDuration(
            now: 100, firstSpeechAt: 95, lastChangeAt: 99,
            hasVolatileText: true, hasReceivedFinalResult: false))
    }

    func testMaxDurationCommitsAtWordBoundaryPastCap() {
        let d = decider(maxUtterance: 10)
        // Spoken 11s (≥ cap) and last word was 1.0s ago (≥ 0.35 grace) → commit.
        XCTAssertTrue(d.shouldEndpointForMaxDuration(
            now: 100, firstSpeechAt: 89, lastChangeAt: 99,
            hasVolatileText: true, hasReceivedFinalResult: false))
    }

    func testMaxDurationDefersMidWord() {
        let d = decider(maxUtterance: 10)
        // Spoken 11s (≥ cap) but still producing words (0.1s < 0.35 grace) → defer.
        XCTAssertFalse(d.shouldEndpointForMaxDuration(
            now: 100, firstSpeechAt: 89, lastChangeAt: 99.9,
            hasVolatileText: true, hasReceivedFinalResult: false))
    }

    func testMaxDurationHardCeilingOverridesGrace() {
        let d = decider(maxUtterance: 10)
        // Spoken 14s (≥ cap + 3s ceiling) — commits even mid-word.
        XCTAssertTrue(d.shouldEndpointForMaxDuration(
            now: 100, firstSpeechAt: 86, lastChangeAt: 99.99,
            hasVolatileText: true, hasReceivedFinalResult: false))
    }

    func testMaxDurationDisabledWhenZero() {
        let d = decider(maxUtterance: 0)
        XCTAssertFalse(d.shouldEndpointForMaxDuration(
            now: 100, firstSpeechAt: 50, lastChangeAt: 99,   // spoken 50s, still off
            hasVolatileText: true, hasReceivedFinalResult: false))
    }

    // MARK: - Acoustic-VAD stop policy

    func testNoSpeechStopsOnlyWhenNoTextProduced() {
        XCTAssertTrue(EndpointDecider.shouldStop(
            for: .noSpeech, hasVolatileText: false, hasReceivedFinalResult: false))
        // Text exists — a quiet speaker under AGC; defer to the stability endpoint.
        XCTAssertFalse(EndpointDecider.shouldStop(
            for: .noSpeech, hasVolatileText: true, hasReceivedFinalResult: false))
    }

    func testEndOfSpeechStopsOnceAnyTextExists() {
        XCTAssertTrue(EndpointDecider.shouldStop(
            for: .endOfSpeech, hasVolatileText: true, hasReceivedFinalResult: false))
        XCTAssertTrue(EndpointDecider.shouldStop(
            for: .endOfSpeech, hasVolatileText: false, hasReceivedFinalResult: true))
        XCTAssertFalse(EndpointDecider.shouldStop(
            for: .endOfSpeech, hasVolatileText: false, hasReceivedFinalResult: false))
    }
}
