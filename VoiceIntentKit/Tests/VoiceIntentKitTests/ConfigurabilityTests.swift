// ConfigurabilityTests.swift
// VoiceIntentKitTests
//
// The production-readiness fixes: language-configurable trailing function words
// (the smart-endpointing heuristic), the app-provided-audio fail-fast, and that the
// audio push API is a safe no-op when the package owns the mic.

import XCTest
import Foundation
@testable import VoiceIntentKit

final class ConfigurabilityTests: XCTestCase {

    // MARK: - Trailing function words (content-aware endpointing)

    /// Builds a real pack-backed engine with an optional custom trailing-word set.
    private func engine(trailing: Set<String>?) throws -> any ConversationEngine {
        try PackEngineFactory.makeEngine(
            pack: try PackTestSupport.loadPack(),
            trailingFunctionWords: trailing)
    }

    private func assertIncomplete(_ v: SlotAnswerAssessment, _ message: String) {
        if case .incomplete = v { return }
        XCTFail("\(message): expected .incomplete, got \(v)")
    }

    private func assertComplete(_ v: SlotAnswerAssessment, _ message: String) {
        if case .complete = v { return }
        XCTFail("\(message): expected .complete, got \(v)")
    }

    /// With the default (English) set, a command ending on a function word is judged
    /// mid-thought, and a self-contained command is complete.
    func testEnglishDefaultTrailingWords() async throws {
        let e = try engine(trailing: nil)
        assertIncomplete(await e.assessSlotAnswer("set the volume to"),
                         "'…to' is an English trailing word")
        assertComplete(await e.assessSlotAnswer("increase volume"),
                       "a complete command")
        // A word outside the English set is not detected — this is the multilingual gap.
        assertComplete(await e.assessSlotAnswer("say blorp"),
                       "'blorp' is not in the English default set")
    }

    /// Injecting a custom set makes the endpointer recognise it — the fix that lets a
    /// non-English pack supply its own trailing words.
    func testCustomTrailingWordsAreInjected() async throws {
        let e = try engine(trailing: ["blorp"])
        assertIncomplete(await e.assessSlotAnswer("say blorp"),
                         "custom trailing word should now extend the window")
    }

    // MARK: - App-provided audio fail-fast

    /// `.appProvided` audio + internal TTS is an unreconcilable combination (the host
    /// owns the audio session), so `start()` must refuse it before touching hardware.
    @MainActor
    func testAppProvidedAudioWithInternalTTSFailsFast() async throws {
        let config = VoiceIntentConfiguration(
            language: .english,
            packProvider: StaticPackProvider(language: "en", url: try PackTestSupport.packRoot()),
            trust: PackTestSupport.trust,
            speaksPrompts: true,                              // the conflict
            audioSource: .appProvided(sampleRate: 16_000))
        let session = VoiceIntentSession(configuration: config)

        do {
            try await session.start()
            XCTFail("app-provided audio + internal TTS must fail fast")
        } catch let error as VoiceIntentConfigurationError {
            XCTAssertEqual(error, .internalTTSUnavailableWithAppProvidedAudio)
        }
    }

    /// A valid app-provided config (external TTS) should NOT trip the fail-fast — the
    /// error is specific to the internal-TTS conflict, not to app audio itself.
    @MainActor
    func testAppProvidedAudioWithExternalTTSDoesNotFailFast() throws {
        // Constructing the session and its push provider must not throw.
        let config = VoiceIntentConfiguration(
            language: .english,
            packProvider: StaticPackProvider(language: "en", url: try PackTestSupport.packRoot()),
            trust: PackTestSupport.trust,
            speaksPrompts: false,                             // external TTS — allowed
            audioSource: .appProvided(sampleRate: 16_000))
        let session = VoiceIntentSession(configuration: config)
        // provideAudio before start() is a harmless no-op (no active turn).
        session.provideAudio(Data([0x01, 0x02]))
    }

    /// The push API is a no-op for a microphone-source session (nil provider) and
    /// must never crash if the host calls it by mistake.
    @MainActor
    func testProvideAudioIsNoopForMicrophoneSource() throws {
        let config = VoiceIntentConfiguration(
            language: .english,
            packProvider: StaticPackProvider(language: "en", url: try PackTestSupport.packRoot()),
            trust: PackTestSupport.trust,
            speaksPrompts: false)                             // .microphone by default
        let session = VoiceIntentSession(configuration: config)
        session.provideAudio(Data([0x01, 0x02, 0x03, 0x04]))  // no crash, no effect
    }
}
