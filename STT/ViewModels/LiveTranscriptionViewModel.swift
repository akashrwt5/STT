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
    private let engine: AVAudioEngine
    private let logger = Logger(subsystem: "com.stt.module", category: "LiveTranscriptionViewModel")

    // MARK: - Init

    public init(coordinator: TranscriptionCoordinator, engine: AVAudioEngine = AVAudioEngine()) {
        self.coordinator = coordinator
        self.engine = engine
        self.currentLocale = coordinator.currentLocale
        coordinator.delegate = self
    }

    // MARK: - Public API

    /// Toggles recording on/off.
    public func toggleRecording() {
        if isListening {
            stopRecording()
        } else {
            startRecording()
        }
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

    /// Clears all stored final results.
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
                startAudioLevelMetering()
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
        stopAudioLevelMetering()
        audioLevel = 0.0
    }

    // MARK: - Audio Level Metering

    private func startAudioLevelMetering() {
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let level = self.computeLevel(buffer: buffer)
            Task { @MainActor in self.audioLevel = level }
        }

        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // Timer keeps the run loop alive for the tap callback; actual level is set in tap.
            _ = self
        }
    }

    private func stopAudioLevelMetering() {
        levelTimer?.invalidate()
        levelTimer = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    private func computeLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }
        let frameLength = Int(buffer.frameLength)
        var rms: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[0][i]
            rms += sample * sample
        }
        rms = frameLength > 0 ? sqrt(rms / Float(frameLength)) : 0
        // Normalize to 0–1
        return min(1.0, rms * 10)
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
        stopAudioLevelMetering()
    }

    public func didChangeState(_ state: TranscriptionState) {
        transcriptionState = state
        audioSource = coordinator.currentRoute.name
    }
}
