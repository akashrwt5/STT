// ConversationSpeaker.swift
// STT
//
// Wraps AVSpeechSynthesizer so the NLU conversation can speak follow-up
// questions and fulfillment messages aloud, and notify when it finishes
// (so the view model can auto-restart listening for the user's answer).

import AVFoundation
import os.log

@MainActor
public final class ConversationSpeaker: NSObject, AVSpeechSynthesizerDelegate {

    private let synthesizer = AVSpeechSynthesizer()
    private let logger = Logger(subsystem: "com.stt.module", category: "ConversationSpeaker")

    /// Called on the main actor when an utterance finishes *normally*. This is the
    /// signal to auto-resume listening for the user's answer.
    public var onFinish: (() -> Void)?

    /// Called on the main actor when speech is cancelled — either by an explicit `stop()`
    /// or by an external interruption (phone call, system audio). Does NOT auto-resume
    /// listening; it only lets the owner clear its own speaking state so input isn't
    /// dropped forever. Without this, an interrupted utterance leaves `isSpeaking` stuck.
    public var onCancel: (() -> Void)?

    public private(set) var isSpeaking = false

    /// Cancels the in-flight safety timeout when a delegate callback fires first.
    private var timeoutTask: Task<Void, Never>?

    /// Maximum seconds to wait for a delegate callback before force-resetting state.
    /// Covers any TTS failure mode where didFinish/didCancel never fires.
    private static let timeoutSeconds: Double = 15

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text`. Configures the audio session for playback first so the
    /// voice is audible even right after recording.
    public func speak(_ text: String, locale: Locale) {
        isSpeaking = true
        scheduleTimeout()
        Task {
            await configureSessionForPlayback()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: locale.identifier)
                ?? AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.postUtteranceDelay = 0.1
            synthesizer.speak(utterance)
        }
    }

    /// Stops any in-progress speech immediately (does not fire `onFinish`).
    public func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// Schedules a watchdog that force-resets speaking state if no delegate callback
    /// arrives within `timeoutSeconds`. Prevents isSpeaking from getting permanently
    /// stuck when TTS fails silently (session error, hardware interruption, etc.).
    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isSpeaking else { return }
                self.logger.warning("TTS safety timeout fired — didFinish/didCancel never received. Force-resetting isSpeaking.")
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                self.isSpeaking = false
                self.timeoutTask = nil
                self.onCancel?()
            }
        }
    }

    /// Configures the audio session for TTS playback off the main actor so the
    /// blocking `setActive` call does not freeze the UI (RC3).
    private func configureSessionForPlayback() async {
        nonisolated(unsafe) let session = AVAudioSession.sharedInstance()
        do {
            try await Task.detached(priority: .userInitiated) {
                try session.setCategory(.playAndRecord,
                                        mode: .spokenAudio,
                                        options: [.defaultToSpeaker, .duckOthers, .allowBluetooth])
                try session.setActive(true)
            }.value
        } catch {
            logger.error("configureSessionForPlayback failed: \(error)")
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            // Deactivate the playback session so AudioSessionManager.configure() starts
            // from a clean state instead of inheriting .playAndRecord/.spokenAudio (RC1).
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.isSpeaking = false
            self.onFinish?()
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.isSpeaking = false
            self.onCancel?()
        }
    }
}
