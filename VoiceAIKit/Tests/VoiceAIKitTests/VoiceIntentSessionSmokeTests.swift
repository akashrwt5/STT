// VoiceIntentSessionSmokeTests.swift
// VoiceAIKitTests
//
// The public facade, end to end: a host supplies a pack URL, the session
// verifies and binds it, and `classify(text:)` returns something sane.
//
// REWRITTEN for the pack path. The previous version asserted that French
// overlays resolved from `Bundle.module`, and constructed a session with only a
// language code — both of which encoded the behaviour this refactor removes. In
// particular its French case could not fail for the right reason: if the overlay
// had NOT loaded, the session fell back to the English schema and still returned
// a "plausible" turn, which the test accepted.
//
// No microphone — text-only.

import XCTest
@testable import VoiceAIKit

final class VoiceIntentSessionSmokeTests: XCTestCase {

    /// Stands in for a host's download layer: the pack is already on disk.
    private func provider() throws -> StaticPackProvider {
        StaticPackProvider(language: "en", url: try PackTestSupport.packRoot())
    }

    private func configuration() throws -> VoiceIntentConfiguration {
        .init(language: .english,
              packProvider: try provider(),
              trust: PackTestSupport.trust,
              speaksPrompts: false,          // no TTS in tests
              autoStopOnSilence: true,
              loadsSemanticRescue: false)    // the pack disables Stage 3 anyway
    }

    @MainActor
    func testClassifyReturnsAPlausibleTurn() async throws {
        let session = VoiceIntentSession(configuration: try configuration())
        let turn = try await session.classify(text: "turn up the volume")

        XCTAssertTrue(Self.isPlausible(turn),
                      "'turn up the volume' should produce a usable turn, got \(turn)")
    }

    /// The behaviour that replaces the old French test.
    ///
    /// Asking for a language the provider does not have must THROW. The point is
    /// not that the error is pretty — it is that the session refuses rather than
    /// starting in a language the caller did not ask for. Under the old code this
    /// path logged and returned an English engine, so a French session that never
    /// loaded French was indistinguishable from one that did.
    @MainActor
    func testUnavailableLanguageThrowsRatherThanFallingBackToEnglish() async throws {
        var config = try configuration()
        config.language = .language(code: "fr", locale: "fr-FR")
        let session = VoiceIntentSession(configuration: config)

        do {
            _ = try await session.classify(text: "monte le volume")
            XCTFail("a session with no French pack must not answer in English")
        } catch let error as VoiceIntentError {
            guard case .languageUnavailable(let requested, _) = error else {
                return XCTFail("expected .languageUnavailable, got \(error)")
            }
            XCTAssertEqual(requested, "fr")
        }
    }

    /// A pack directory that is not there is an error, not a fallback.
    @MainActor
    func testMissingPackThrows() async throws {
        var config = try configuration()
        config.packProvider = StaticPackProvider(
            language: "en",
            url: URL(fileURLWithPath: "/nonexistent/pack-en"))
        let session = VoiceIntentSession(configuration: config)

        do {
            _ = try await session.classify(text: "turn up the volume")
            XCTFail("a missing pack must not produce a working session")
        } catch let error as VoiceIntentError {
            guard case .packNotFound = error else {
                return XCTFail("expected .packNotFound, got \(error)")
            }
        }
    }

    @MainActor
    func testStartNextListeningTurnFromIdleThrowsWithoutMic() async throws {
        let session = VoiceIntentSession(configuration: try configuration())
        XCTAssertEqual(session.state, .idle, "Fresh session must start in .idle")
        
        do {
            // This is allowed from .idle, but will throw deep inside the coordinator
            // because the test environment lacks microphone permissions/hardware.
            try await session.startNextListeningTurn()
            XCTFail("startNextListeningTurn() must throw when audio stack cannot start")
        } catch {
            // We expect an error here, but we also proved the method was invoked and 
            // didn't return early from its state guard.
        }
    }

    // MARK: - stop() actually stops

    /// A turn outcome must never be applied to a session the host is not running.
    ///
    /// Regression for: `didReceiveFinalResult` launched an unowned `Task` that `stop()`
    /// did not cancel, and nothing downstream asked whether the session was still
    /// wanted. The task finished its `await`, called `apply`, and drove a whole turn —
    /// speaking aloud, arming the 30s external-TTS watchdog, and reopening the
    /// microphone — after the user had stopped. `started` was written twice and read in
    /// none, so the flag that should have prevented it was inert.
    ///
    /// SCOPE: this drives the delegate callback directly, so it covers the guard on the
    /// entry path (`started == false`). The true race — `stop()` landing *during*
    /// `engine.handle(text)` — needs a live microphone session and is covered by the
    /// guards at `apply()` and `handleTurnAdvance()`, verified manually (speak, then tap
    /// stop the moment the UI shows "thinking").
    @MainActor
    func testFinalTranscriptOnAStoppedSessionProducesNoTurn() async throws {
        let session = VoiceIntentSession(configuration: try configuration())

        // Build the engine without a microphone. After this `engine != nil`, which is
        // what `didReceiveFinalResult` needs in order to reach the classifier at all —
        // so if the guard were missing, this test would exercise the full turn path.
        _ = try await session.classify(text: "turn up the volume")
        XCTAssertEqual(session.state, .idle, "classify(text:) must not move the session")

        var events: [VoiceIntentEvent] = []
        let collector = Task { for await event in session.events { events.append(event) } }
        defer { collector.cancel() }

        // The session was never started (equivalently: has been stopped).
        session.didReceiveFinalResult("turn up the volume")

        // Give any leaked task the main-actor hops it would need to run to completion.
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(session.state, .idle,
                       "a stopped session must stay put, not move to .thinking/.listening")
        for event in events {
            switch event {
            case .turn:
                XCTFail("a turn was applied to a session that is not running")
            case .finalTranscript:
                XCTFail("a final transcript was reported for a session that is not running")
            case .stateChanged(let state) where state == .listening || state == .speaking:
                XCTFail("the session came back to \(state) after being stopped")
            default:
                continue
            }
        }
    }

    /// The OTHER door to `.stopped`: a fatal transcription error.
    ///
    /// Regression for the hole in the first cut of the stop() fix — it cleared the
    /// "host wants this running" flag in `stop()` only, so a session killed by a mic
    /// failure kept the flag set and an in-flight turn could still run and reopen the
    /// microphone. Both doors now go through `markNotRunning()`.
    @MainActor
    func testFatalErrorAlsoStopsTheSessionForRealNotJustInName() async throws {
        let session = VoiceIntentSession(configuration: try configuration())
        _ = try await session.classify(text: "turn up the volume")   // build the engine

        session.didEncounterError(.deviceNotSupported)
        XCTAssertEqual(session.state, .stopped)

        var events: [VoiceIntentEvent] = []
        let collector = Task { for await event in session.events { events.append(event) } }
        defer { collector.cancel() }

        // A final result still in flight from the coordinator when the error landed.
        session.didReceiveFinalResult("turn up the volume")
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(session.state, .stopped,
                       "a session killed by an error must stay stopped")
        for event in events {
            if case .turn = event {
                XCTFail("a turn ran on a session that a fatal error had already stopped")
            }
            if case .stateChanged(let state) = event, state == .listening || state == .speaking {
                XCTFail("the session came back to \(state) after a fatal error")
            }
        }
    }

    /// An abandoned multi-turn conversation must not survive into the next `start()`.
    ///
    /// Regression for the divergence between the two halves of the conversation state:
    /// `NLUEngine.handle()` sets `pendingIntent` / `awaitingSlot` before it returns, so a
    /// turn that is never applied leaves the engine mid-slot-filling while the session
    /// has forgotten. The next utterance was then eaten as the answer to a question the
    /// user never heard — "set a reminder", stop, start, "turn up the volume", and the
    /// reminder gets named "turn up the volume".
    ///
    /// Driven through `classify(text:)` because it shares the engine with the microphone
    /// path; no mic needed to show the engine holding state across a stop.
    @MainActor
    func testAbandonedConversationDoesNotLeakIntoTheNextTurn() async throws {
        let session = VoiceIntentSession(configuration: try configuration())

        // Ask for something with required slots so the engine starts collecting.
        let opener = try await session.classify(text: "set a reminder")
        guard case .followUp = opener else {
            throw XCTSkip("this pack did not ask a follow-up for 'set a reminder' (got \(opener)); the leak needs a slot-filling engine state to be visible")
        }

        // The user walks away: the session is stopped mid-question.
        session.stop()
        XCTAssertEqual(session.state, .stopped)

        // A brand-new conversation.
        //
        // `try?`, not `try`: without a microphone `start()` throws inside
        // `beginListening()` — but it throws AFTER the engine reset, which is the line
        // under test. `testStartNextListeningTurnFromIdleThrowsWithoutMic` above relies
        // on the same environment fact.
        try? await session.start()
        defer { session.stop() }

        let next = try await session.classify(text: "turn up the volume")
        if case .followUp = next {
            XCTFail("'turn up the volume' was swallowed as the answer to the abandoned reminder question")
        }
    }

    /// `stop()` is safe to call at any time and always lands in `.stopped`.
    @MainActor
    func testStopFromIdleIsStopped() throws {
        let session = VoiceIntentSession(configuration: try configuration())
        session.stop()
        XCTAssertEqual(session.state, .stopped)
    }

    // MARK: - Helpers

    /// A turn is "plausible" if it names an intent, asks a follow-up, or hands
    /// back the fallback URL. All three mean the pipeline resolved its pack and
    /// produced something; which one is a question for the parity suites.
    private static func isPlausible(_ turn: VoiceIntentTurn) -> Bool {
        switch turn {
        case .fulfilled(let intent, _, _, _, _, _):
            return !intent.isEmpty
        case .followUp, .confirmation, .notUnderstood, .interrupted:
            return true
        }
    }
}
