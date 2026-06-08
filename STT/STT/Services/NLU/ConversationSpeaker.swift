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
    /// Monotonic counter so each speak/finish pair can be correlated in the log.
    private var utteranceIndex = 0

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
    public func speak(_ text: String, locale: Locale) {
        utteranceIndex += 1
        let idx = utteranceIndex

        // [DIAG-RC1] Log the session state BEFORE reconfiguring for playback.
        // If this shows the category is NOT .record on the first call, or shows
        // a non-idle state on later calls, that confirms the session was never
        // properly reset after a previous TTS session.
        let sessionBefore = AVAudioSession.sharedInstance()
        logger.warning("[DIAG-RC1][#\(idx)] speak() called. Session BEFORE configureForPlayback → category: \(sessionBefore.category.rawValue), mode: \(sessionBefore.mode.rawValue), isActive (inferred from category): \(sessionBefore.category != .ambient)")

        configureSessionForPlayback(index: idx)

        // [DIAG-RC2] Log isSpeaking state. If this is already `true` when speak()
        // is called, a previous TTS cycle never fired didFinish/didCancel, which
        // means onFinish never ran and the mic was never restarted. That is the
        // isSpeaking-stuck bug.
        if isSpeaking {
            logger.error("[DIAG-RC2][#\(idx)] speak() called while isSpeaking is already TRUE — previous utterance never fired didFinish/didCancel. This confirms isSpeaking can get stuck.")
        }
        isSpeaking = true
        logger.info("[DIAG][#\(idx)] isSpeaking set to TRUE. synthesizer.isSpeaking=\(self.synthesizer.isSpeaking)")

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: locale.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1
        synthesizer.speak(utterance)
        logger.info("[DIAG][#\(idx)] synthesizer.speak() called. synthesizer.isSpeaking=\(self.synthesizer.isSpeaking)")
    }

    /// Stops any in-progress speech immediately (does not fire `onFinish`).
    public func stop() {
        logger.info("[DIAG] stop() called. synthesizer.isSpeaking=\(self.synthesizer.isSpeaking), isSpeaking=\(self.isSpeaking)")
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func configureSessionForPlayback(index: Int) {
        let session = AVAudioSession.sharedInstance()

        // [DIAG-RC3] setCategory and setActive are synchronous on the main actor.
        // The timestamps in the log will show how long these block.
        logger.info("[DIAG-RC3][#\(index)] configureSessionForPlayback — calling setCategory(.playAndRecord) on main actor (may block 100–300ms).")
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .spokenAudio,
                                    options: [.defaultToSpeaker, .duckOthers, .allowBluetooth])
            logger.info("[DIAG-RC3][#\(index)] setCategory(.playAndRecord) succeeded.")
        } catch {
            logger.error("[DIAG-RC3][#\(index)] setCategory(.playAndRecord) FAILED: \(error) — TTS may not speak, and didFinish may never fire (isSpeaking gets stuck).")
        }

        do {
            try session.setActive(true)
            logger.info("[DIAG-RC3][#\(index)] setActive(true) for playback succeeded. Session now: category=\(session.category.rawValue), mode=\(session.mode.rawValue)")
        } catch {
            logger.error("[DIAG-RC3][#\(index)] setActive(true) for playback FAILED: \(error) — TTS may not speak, and didFinish may never fire (isSpeaking gets stuck).")
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // [DIAG-RC1] Log session state at the moment didFinish fires — BEFORE
            // onFinish() triggers startRecording() → sessionManager.configure().
            // If this shows .playAndRecord here, it confirms the session is still
            // active in playback mode when recording tries to restart.
            let session = AVAudioSession.sharedInstance()
            self.logger.warning("[DIAG-RC1] didFinish fired. Session is STILL active in: category=\(session.category.rawValue), mode=\(session.mode.rawValue). setActive(false) has NOT been called — this is the dirty session passed to the next recording start.")
            self.isSpeaking = false
            self.logger.info("[DIAG] isSpeaking set to FALSE via didFinish. Calling onFinish.")
            self.onFinish?()
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let session = AVAudioSession.sharedInstance()
            self.logger.info("[DIAG-RC1] didCancel fired. Session: category=\(session.category.rawValue), mode=\(session.mode.rawValue).")
            self.isSpeaking = false
            self.logger.info("[DIAG] isSpeaking set to FALSE via didCancel. Calling onCancel.")
            self.onCancel?()
        }
    }
}
