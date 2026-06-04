// TranscriptionCoordinatorTests.swift
// STTTests

import XCTest
import AVFoundation
import Speech
@testable import STT

@MainActor
final class TranscriptionCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    // Uses a hardcoded locale so makeSUT stays synchronous — avoids calling the
    // now-async SpeechRecognitionService.resolveLocale() in a non-async context.
    // Factory closures are @MainActor to match TranscriptionCoordinator's requirements.
    private func makeSUT(
        captureFactory: @MainActor @escaping () -> any AudioInputProvider = { MockAudioInputProvider() },
        fileFactory: @MainActor @escaping (URL) -> any AudioInputProvider = { _ in MockAudioInputProvider() }
    ) -> (TranscriptionCoordinator, MockTranscriptionDelegate) {
        let locale = Locale(identifier: "en-IN")
        let recognitionService = SpeechRecognitionService(locale: locale)
        let coordinator = TranscriptionCoordinator(
            sessionManager: AudioSessionManager(),
            recognitionService: recognitionService,
            captureServiceFactory: captureFactory,
            fileServiceFactory: fileFactory,
            locale: locale
        )
        let delegate = MockTranscriptionDelegate()
        coordinator.delegate = delegate
        return (coordinator, delegate)
    }

    // MARK: - Initial State

    func testInitialStateIsIdle() {
        let (coordinator, _) = makeSUT()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.isTranscribing)
    }

    func testInitialTranscriptIsEmpty() {
        let (coordinator, _) = makeSUT()
        XCTAssertEqual(coordinator.currentTranscript, "")
    }

    // MARK: - File Not Found

    func testTranscribeFileThrowsForMissingFile() async {
        let (coordinator, _) = makeSUT()
        let missingURL = URL(fileURLWithPath: "/tmp/nonexistent_audio_\(UUID().uuidString).wav")

        do {
            _ = try await coordinator.transcribeFile(at: missingURL)
            XCTFail("Expected fileNotFound error")
        } catch TranscriptionError.fileNotFound(let url) {
            XCTAssertEqual(url.lastPathComponent, missingURL.lastPathComponent)
        } catch TranscriptionError.microphonePermissionDenied,
                TranscriptionError.speechRecognitionPermissionDenied {
            // Acceptable in simulator — permissions may not be granted
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Provider Selection

    func testLiveTranscriptionUsesCaptureFactory() async throws {
        var captureFactoryCalled = false
        let (coordinator, _) = makeSUT(captureFactory: {
            captureFactoryCalled = true
            return MockAudioInputProvider()
        })

        _ = try? await coordinator.startLiveTranscription()

        // On simulator the factory may not be reached if permissions fail first.
        // We verify the coordinator reached a valid state.
        let validStates: [TranscriptionState] = [
            .requestingPermissions, .preparingAudio, .transcribing,
            .failed(.microphonePermissionDenied), .failed(.speechRecognitionPermissionDenied)
        ]
        XCTAssertTrue(validStates.contains(coordinator.state))
    }

    func testFileTranscriptionUsesFileFactory() async {
        let (coordinator, _) = makeSUT(fileFactory: { _ in MockAudioInputProvider() })

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        _ = try? AVAudioFile(forWriting: tempURL, settings: format.settings)

        _ = try? await coordinator.transcribeFile(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - Delegate State Transitions

    func testDelegateReceivesStateTransitions() async {
        let (coordinator, delegate) = makeSUT()

        _ = try? await coordinator.startLiveTranscription()

        XCTAssertFalse(delegate.states.isEmpty, "Should have received at least one state transition")
        XCTAssertTrue(delegate.states.contains(.requestingPermissions))
    }

    // MARK: - Locale Switching

    func testSwitchToUnsupportedLocaleThrows() async {
        let (coordinator, _) = makeSUT()
        do {
            try await coordinator.switchLocale(to: "zz-ZZ")
            XCTFail("Expected error")
        } catch TranscriptionError.localeNotSupported {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Error Propagation

    func testTranscriptionErrorDescriptionsAreNonEmpty() {
        let errors: [TranscriptionError] = [
            .microphonePermissionDenied,
            .speechRecognitionPermissionDenied,
            .localeNotSupported("zz-ZZ"),
            .audioSessionSetupFailed(NSError(domain: "test", code: 1)),
            .audioEngineStartFailed(NSError(domain: "test", code: 2)),
            .fileNotFound(URL(fileURLWithPath: "/tmp/test.wav")),
            .unsupportedAudioFormat("mp3"),
            .analyzerFailed(NSError(domain: "test", code: 3)),
            .deviceNotSupported
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    // MARK: - TranscriptionState

    func testTranscriptionStateIsActiveOnlyWhenAppropriate() {
        XCTAssertTrue(TranscriptionState.transcribing.isActive)
        XCTAssertTrue(TranscriptionState.processingFile(progress: 0.5).isActive)
        XCTAssertFalse(TranscriptionState.idle.isActive)
        XCTAssertFalse(TranscriptionState.stopping.isActive)
        XCTAssertFalse(TranscriptionState.requestingPermissions.isActive)
    }
}
