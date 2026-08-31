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
