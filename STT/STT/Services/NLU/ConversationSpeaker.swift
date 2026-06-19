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

    // Latency instrumentation (logging only — no behaviour change). `requestedAt`
    // is the moment the final STT result arrived (passed in by the view model) so
    // `didStart` can report the full "user stopped talking → first TTS audio"
    // delay. Filter Console.app / `log stream` by subsystem com.stt.module,
    // category Latency.
    private static let latencyLog = Logger(subsystem: "com.stt.module", category: "Latency")
    private var requestedAt: CFAbsoluteTime?

    /// Called on the main actor when an utterance finishes *normally*. This is the
    /// signal to auto-resume listening for the user's answer.
    public var onFinish: (() -> Void)?

    /// Called on the main actor when speech is cancelled — either by an explicit `stop()`
    /// or by an external interruption (phone call, system audio). Does NOT auto-resume
    /// listening; it only lets the owner clear its own speaking state so input isn't
    /// dropped forever. Without this, an interrupted utterance leaves `isSpeaking` stuck.
    public var onCancel: (() -> Void)?

    public private(set) var isSpeaking = false

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text`. Configures the audio session for playback first so the
    /// voice is audible even right after recording.
    ///
    /// - Parameter requestedAt: optional `CFAbsoluteTimeGetCurrent()` captured when
    ///   the triggering STT result arrived, used only to log end-to-end latency.
    public func speak(_ text: String, locale: Locale, requestedAt: CFAbsoluteTime? = nil) {
        self.requestedAt = requestedAt

        let configStart = CFAbsoluteTimeGetCurrent()
        configureSessionForPlayback()
        let configMs = (CFAbsoluteTimeGetCurrent() - configStart) * 1000

        isSpeaking = true

        let voiceStart = CFAbsoluteTimeGetCurrent()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: locale.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        let voiceMs = (CFAbsoluteTimeGetCurrent() - voiceStart) * 1000

        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1

        Self.latencyLog.info("speak() configureSession=\(configMs, format: .fixed(precision: 1))ms voiceLoad=\(voiceMs, format: .fixed(precision: 1))ms")
        synthesizer.speak(utterance)
    }

    /// Stops any in-progress speech immediately (does not fire `onFinish`).
    public func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func configureSessionForPlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 mode: .spokenAudio,
                                 options: [.defaultToSpeaker, .duckOthers, .allowBluetooth])
        try? session.setActive(true)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let requestedAt = self.requestedAt else { return }
            let totalMs = (CFAbsoluteTimeGetCurrent() - requestedAt) * 1000
            Self.latencyLog.info("FIRST AUDIO: \(totalMs, format: .fixed(precision: 1))ms after final STT result")
            self.requestedAt = nil
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onFinish?()
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onCancel?()
        }
    }
}
