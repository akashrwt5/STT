// SilenceDetectorTests.swift
// VoiceAIKitTests
//
// The acoustic VAD is pure, frame-by-frame logic — no AVAudioEngine, no clock —
// so it is fully unit-testable by feeding synthetic dBFS/frame sequences. These
// pin the two timeouts (end-of-speech, no-speech), the "speech resets the silence
// run" rule that keeps a mid-sentence pause from cutting the user off, and that a
// disabled config never fires.

import XCTest
@testable import VoiceAIKit

final class SilenceDetectorTests: XCTestCase {

    private let sampleRate: Double = 16_000
    /// One 0.1s frame at 16 kHz.
    private let frame = 1_600
    private let speechDBFS: Float = -20   // comfortably above the −45 default threshold
    private let silenceDBFS: Float = -70  // comfortably below it

    private func detector(_ config: SilenceDetectionConfiguration) -> SilenceDetector {
        SilenceDetector(configuration: config, sampleRate: sampleRate)
    }

    // MARK: - No-speech timeout (nobody ever spoke)

    func testNoSpeechTimeoutFiresWhenSilentFromTheStart() {
        let d = detector(.init(isEnabled: true, noSpeechTimeout: 1.0))
        var outcome: SilenceDetector.Outcome = .ongoing
        // 10 × 0.1s = 1.0s of pure silence.
        for _ in 0..<10 { outcome = d.process(powerDBFS: silenceDBFS, frames: frame) }
        XCTAssertEqual(outcome, .silenceDetected(reason: .noSpeech))
    }

    func testNoSpeechDoesNotFireBeforeTimeout() {
        let d = detector(.init(isEnabled: true, noSpeechTimeout: 1.0))
        var outcome: SilenceDetector.Outcome = .ongoing
        // 0.5s only — below the 1.0s window.
        for _ in 0..<5 { outcome = d.process(powerDBFS: silenceDBFS, frames: frame) }
        XCTAssertEqual(outcome, .ongoing)
    }

    // MARK: - End-of-speech timeout (spoke, then trailed off)

    func testEndOfSpeechFiresAfterSpeechThenSilence() {
        let d = detector(.init(isEnabled: true, speechEndTimeout: 1.0))
        _ = d.process(powerDBFS: speechDBFS, frames: frame)   // the user speaks
        var outcome: SilenceDetector.Outcome = .ongoing
        for _ in 0..<10 { outcome = d.process(powerDBFS: silenceDBFS, frames: frame) } // 1.0s silence
        XCTAssertEqual(outcome, .silenceDetected(reason: .endOfSpeech))
    }

    // MARK: - Mid-sentence pause must NOT cut the user off

    func testShortPauseThenMoreSpeechStaysOngoing() {
        let d = detector(.init(isEnabled: true, speechEndTimeout: 1.0))
        _ = d.process(powerDBFS: speechDBFS, frames: frame)   // speech

        // 0.5s pause (< 1.0s window) — should not endpoint.
        for _ in 0..<5 {
            XCTAssertEqual(d.process(powerDBFS: silenceDBFS, frames: frame), .ongoing)
        }
        // The user resumes — this resets the silence run.
        XCTAssertEqual(d.process(powerDBFS: speechDBFS, frames: frame), .ongoing)
        // Another 0.5s pause — still under the window because the run restarted.
        for _ in 0..<5 {
            XCTAssertEqual(d.process(powerDBFS: silenceDBFS, frames: frame), .ongoing)
        }
    }

    // MARK: - Disabled

    func testDisabledConfigNeverEndpoints() {
        let d = detector(.disabled)
        // A huge silent run still returns .ongoing when detection is off.
        XCTAssertEqual(d.process(powerDBFS: silenceDBFS, frames: frame * 100), .ongoing)
    }

    // MARK: - Threshold configurability

    func testStricterThresholdTreatsNormalSpeechLevelAsSilence() {
        // With a −10 dBFS threshold, −30 dBFS (a normal speaking level) is below it,
        // so it never counts as speech and the no-speech timeout eventually fires.
        let d = detector(.init(isEnabled: true, thresholdDBFS: -10, noSpeechTimeout: 1.0))
        var outcome: SilenceDetector.Outcome = .ongoing
        for _ in 0..<10 { outcome = d.process(powerDBFS: -30, frames: frame) }
        XCTAssertEqual(outcome, .silenceDetected(reason: .noSpeech))
    }
}
