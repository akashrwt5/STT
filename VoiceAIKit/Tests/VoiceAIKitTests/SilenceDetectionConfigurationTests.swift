// SilenceDetectionConfigurationTests.swift
// VoiceAIKitTests
//
// Pins the endpointing presets and defaults. These values ARE the behaviour: the
// 1.5s sentence-capture window, the slot-answer windows, the runaway cap, and the
// newly-configurable VAD/cap knobs. A silent change to any of them should fail here.

import XCTest
@testable import VoiceAIKit

final class SilenceDetectionConfigurationTests: XCTestCase {

    func testDisabledPreset() {
        XCTAssertFalse(SilenceDetectionConfiguration.disabled.isEnabled)
    }

    func testSingleUtteranceBaseWindowAndAdaptive() {
        let c = SilenceDetectionConfiguration.singleUtterance
        XCTAssertTrue(c.isEnabled)
        XCTAssertEqual(c.speechEndTimeout, 1.0, accuracy: 0.0001)   // industry command base
        XCTAssertTrue(c.adaptiveEndpointing)                        // grows for long utterances
    }

    func testSlotAnswerWindows() {
        let c = SilenceDetectionConfiguration.slotAnswer
        XCTAssertTrue(c.isEnabled)
        XCTAssertEqual(c.speechEndTimeout, 1.5, accuracy: 0.0001)
        XCTAssertEqual(c.freeformAnswerTimeout, 1.5, accuracy: 0.0001)
        XCTAssertEqual(c.incompleteAnswerTimeout, 2.5, accuracy: 0.0001)
    }

    func testDefaultsIncludingNewlyConfigurableKnobs() {
        let c = SilenceDetectionConfiguration(isEnabled: true)
        XCTAssertEqual(c.thresholdDBFS, -45, accuracy: 0.0001)
        XCTAssertEqual(c.noSpeechTimeout, 5.0, accuracy: 0.0001)
        // Runaway guard. It was 12s (Amazon Lex's max-speech), raised to 60s by
        // d9c8562 "fix(voice): stop premature endpointing on multi-clause utterances" —
        // a 12s cap cut people off mid-sentence, and neither preset overrides it, so 60
        // is the value that actually runs. The test kept asserting 12 because this
        // target had not been run in a long while.
        XCTAssertEqual(c.maxUtteranceDuration, 60.0, accuracy: 0.0001)
        // Knobs promoted from hardcoded constants.
        XCTAssertEqual(c.noiseFloorMarginDB, 12.0, accuracy: 0.0001)
        XCTAssertEqual(c.initialNoiseFloorDBFS, -60.0, accuracy: 0.0001)
        XCTAssertEqual(c.maxUtteranceWordBoundaryGrace, 0.35, accuracy: 0.0001)
        XCTAssertEqual(c.maxUtteranceHardCeiling, 3.0, accuracy: 0.0001)
        // Adaptive endpointing defaults (off unless a preset enables it).
        XCTAssertFalse(c.adaptiveEndpointing)
        XCTAssertEqual(c.adaptiveGraceStart, 3.0, accuracy: 0.0001)
        XCTAssertEqual(c.adaptiveSlope, 0.12, accuracy: 0.0001)
        XCTAssertEqual(c.adaptiveMaxWindow, 2.5, accuracy: 0.0001)
    }

    func testCustomValuesAreStored() {
        let c = SilenceDetectionConfiguration(
            isEnabled: true,
            thresholdDBFS: -50,
            noiseFloorMarginDB: 9,
            initialNoiseFloorDBFS: -55,
            speechEndTimeout: 3.0,
            noSpeechTimeout: 8.0,
            maxUtteranceDuration: 20.0,
            maxUtteranceWordBoundaryGrace: 0.5,
            maxUtteranceHardCeiling: 2.0)
        XCTAssertEqual(c.speechEndTimeout, 3.0, accuracy: 0.0001)
        XCTAssertEqual(c.noiseFloorMarginDB, 9, accuracy: 0.0001)
        XCTAssertEqual(c.maxUtteranceDuration, 20.0, accuracy: 0.0001)
        XCTAssertEqual(c.maxUtteranceHardCeiling, 2.0, accuracy: 0.0001)
    }
}
