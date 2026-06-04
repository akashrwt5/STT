// LiveTranscriptionViewModel.swift
// STT

import AVFoundation
import SwiftUI
import os.log

/// View model for the live microphone transcription screen.
@Observable
@MainActor
public final class LiveTranscriptionViewModel {

    // MARK: - Published State

    public private(set) var transcript: String = ""
    public private(set) var isListening: Bool = false
    public private(set) var audioLevel: Float = 0.0
    public private(set) var currentLocale: Locale
    public private(set) var audioSource: String = "iPhone Mic"
    public private(set) var results: [TranscriptionResult] = []
    public private(set) var error: TranscriptionError?
    public private(set) var transcriptionState: TranscriptionState = .idle

    // MARK: - Private

    private let coordinator: TranscriptionCoordinator
    private var levelTimer: Timer?
    private var animPhase: Double = 0
    private let logger = Logger(subsystem: "com.stt.module", category: "LiveTranscriptionViewModel")

    // MARK: - Init

    public init(coordinator: TranscriptionCoordinator) {
        self.coordinator = coordinator
        self.currentLocale = coordinator.currentLocale
        // NOTE: delegate is intentionally NOT set here. `LiveTranscriptionView.init`
        // runs on every parent re-render and eagerly constructs a throwaway view model
        // (SwiftUI keeps only the first `@State` instance). If we set the delegate in
        // `init`, each throwaway instance would steal `coordinator.delegate`, leaving
        // the *displayed* view model unsubscribed — and no transcript on screen.
        // Wiring happens in `activate()`, called from the View's `.onAppear`, which
        // runs on the retained instance.
    }

    // MARK: - Public API

    /// Wires this view model as the coordinator's delegate. Call from `.onAppear` so it
    /// runs on the `@State`-retained instance, not a transient one from a re-render.
    public func activate() {
        coordinator.delegate = self
        currentLocale = coordinator.currentLocale
        audioSource = coordinator.currentRoute.name
    }

    /// Toggles recording on/off.
    public func toggleRecording() {
        if isListening { stopRecording() } else { startRecording() }
    }

    /// Switches the active transcription locale and restarts the session if needed.
    public func switchLocale(_ identifier: String) {
        Task {
            do {
                if isListening { stopRecording() }
                try await coordinator.switchLocale(to: identifier)
                currentLocale = coordinator.currentLocale
            } catch {
                self.error = error as? TranscriptionError
            }
        }
    }

    /// Clears all stored final results and the current transcript.
    public func clearResults() {
        results.removeAll()
        transcript = ""
    }

    // MARK: - Private

    private func startRecording() {
        error = nil
        Task {
            do {
                try await coordinator.startLiveTranscription()
                isListening = true
                startAudioLevelAnimation()
            } catch let err as TranscriptionError {
                self.error = err
                isListening = false
            } catch {
                self.error = .analyzerFailed(error)
                isListening = false
            }
        }
    }

    private func stopRecording() {
        coordinator.stopLiveTranscription()
        isListening = false
        stopAudioLevelAnimation()
    }

    // MARK: - Audio Level Animation
    //
    // AudioCaptureService owns its AVAudioEngine tap exclusively, so we cannot
    // install a second tap for metering without conflicting. Instead we drive a
    // smooth sine-wave animation at 30 fps while recording is active. In a production
    // build, expose a level callback from AudioCaptureService and wire it here.

    private func startAudioLevelAnimation() {
        animPhase = 0
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.animPhase += 0.12
                self.audioLevel = Float(abs(sin(self.animPhase)) * 0.65 + 0.2)
            }
        }
    }

    private func stopAudioLevelAnimation() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0.0
    }
}

// MARK: - TranscriptionDelegate

extension LiveTranscriptionViewModel: TranscriptionDelegate {
    public func didReceivePartialResult(_ text: String) {
        transcript = text
    }

    public func didReceiveFinalResult(_ text: String) {
        transcript = text
        let result = TranscriptionResult(
            text: text,
            isFinal: true,
            locale: currentLocale,
            timestamp: Date()
        )
        results.append(result)
    }

    public func didEncounterError(_ error: TranscriptionError) {
        self.error = error
        isListening = false
        stopAudioLevelAnimation()
    }

    public func didChangeState(_ state: TranscriptionState) {
        transcriptionState = state
        audioSource = coordinator.currentRoute.name
        currentLocale = coordinator.currentLocale
    }
}
