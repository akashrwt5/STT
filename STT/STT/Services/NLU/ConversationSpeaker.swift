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
    private let logger = Logger(subsystem: "com.stt.module", category: "ConversationSpeaker")
    private var requestedAt: CFAbsoluteTime?

    // Watchdog state. AVSpeechSynthesizer can silently drop an utterance (it fires
    // `didFinish` without ever firing `didStart`) when the shared audio session is in
    // a contested state. We tag each `speak()` with a generation and arm a timer; if
    // `didStart` hasn't fired in time we treat it as a failure and recover instead of
    // leaving the conversation deadlocked (mic off, no prompt spoken).
    private var speakGeneration = 0
    private var didStartCurrentUtterance = false
    private static let watchdogTimeout: Duration = .milliseconds(800)

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

    /// Speaks `text`. Re-activates the shared audio session for playback first so
    /// the voice is audible even right after recording.
    ///
    /// The session category is owned by `AudioSessionManager` (a single
    /// `.playAndRecord` configuration shared by mic and TTS) — we deliberately do NOT
    /// switch categories here. Switching `.record` ↔ `.playAndRecord` on every turn
    /// left the session in a contested state and made the synthesizer silently drop
    /// the utterance on the second turn.
    ///
    /// - Parameter requestedAt: optional `CFAbsoluteTimeGetCurrent()` captured when
    ///   the triggering STT result arrived, used only to log end-to-end latency.
    public func speak(_ text: String, locale: Locale, requestedAt: CFAbsoluteTime? = nil) {
        self.requestedAt = requestedAt

        let configStart = CFAbsoluteTimeGetCurrent()
        activateSessionForPlayback()
        let configMs = (CFAbsoluteTimeGetCurrent() - configStart) * 1000

        speakGeneration &+= 1
        let generation = speakGeneration
        didStartCurrentUtterance = false
        isSpeaking = true

        let voiceStart = CFAbsoluteTimeGetCurrent()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: locale.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        let voiceMs = (CFAbsoluteTimeGetCurrent() - voiceStart) * 1000

        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1

        Self.latencyLog.info("speak() activateSession=\(configMs, format: .fixed(precision: 1))ms voiceLoad=\(voiceMs, format: .fixed(precision: 1))ms")
        synthesizer.speak(utterance)
        armWatchdog(for: generation)
    }

    /// Recovers from a silent synthesizer failure: if `didStart` hasn't fired within
    /// `watchdogTimeout`, the utterance was dropped (no audio). Cancel it and notify
    /// the owner so the conversation isn't left deadlocked with the mic off.
    private func armWatchdog(for generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.watchdogTimeout)
            guard let self else { return }
            // Superseded by a newer utterance, or this one started normally — nothing to do.
            guard generation == self.speakGeneration else { return }
            guard self.isSpeaking, !self.didStartCurrentUtterance else { return }

            self.logger.error("TTS watchdog: didStart never fired within 800ms — utterance was silently dropped. Recovering.")
            self.synthesizer.stopSpeaking(at: .immediate)
            self.isSpeaking = false
            self.onCancel?()
        }
    }

    /// Stops any in-progress speech immediately (does not fire `onFinish`).
    public func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// Re-activates the shared session for playback. The category is configured once
    /// by `AudioSessionManager` (`.playAndRecord`) and intentionally left untouched
    /// here. Errors are logged rather than swallowed so a failed activation on a
    /// contested session is visible instead of producing silent dead air.
    private func activateSessionForPlayback() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("setActive(true) for playback failed: \(error.localizedDescription)")
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.didStartCurrentUtterance = true
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
