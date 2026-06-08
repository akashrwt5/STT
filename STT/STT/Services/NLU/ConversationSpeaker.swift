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

    /// Set to `true` when `speak()` calls `stopSpeaking()` to clear a stale utterance
    /// before queuing a new one. Suppresses the resulting `didCancel` callback so that
    /// the new utterance's lifecycle is not disrupted by the cancellation of the old one.
    private var isRestartingSpeak = false

    /// Cancels the in-flight safety timeout when a delegate callback fires first.
    private var timeoutTask: Task<Void, Never>?

    /// Maximum seconds to wait for a delegate callback before force-resetting state.
    /// Covers any TTS failure mode where didFinish/didCancel never fires.
    private static let timeoutSeconds: Double = 8

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text`. Configures the audio session for playback first so the
    /// voice is audible even right after recording.
    public func speak(_ text: String, locale: Locale) {
        let session = AVAudioSession.sharedInstance()
        let routeName = session.currentRoute.outputs.first?.portName ?? "none"
        let routeType = session.currentRoute.outputs.first?.portType.rawValue ?? "none"
        logger.info("speak() — route: \(routeName) (\(routeType)), category: \(session.category.rawValue)")

        // If a previous utterance is still queued or speaking, clear it before queuing
        // the new one. AVSpeechSynthesizer queues rather than replaces, so calling
        // speak() on top of a stuck utterance would leave the new one permanently
        // behind the old one. Set isRestartingSpeak first so that the async didCancel
        // callback the stop triggers doesn't propagate as a real cancellation event.
        if synthesizer.isSpeaking || synthesizer.isPaused {
            logger.warning("speak() — synthesizer already active; clearing stale utterance before queuing new one.")
            isRestartingSpeak = true
            synthesizer.stopSpeaking(at: .immediate)
        }

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
            logger.info("speak() — utterance queued. synthesizer.isSpeaking=\(self.synthesizer.isSpeaking)")
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
                self.logger.warning("TTS safety timeout fired (\(Self.timeoutSeconds)s) — didFinish/didCancel never received. Force-resetting isSpeaking.")
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                self.isSpeaking = false
                self.timeoutTask = nil
                self.onCancel?()
            }
        }
    }

    /// Configures the audio session for TTS playback off the main actor.
    ///
    /// Uses `.playAndRecord` (not `.playback`) so `.defaultToSpeaker` is available —
    /// `.defaultToSpeaker` is only honoured by the `.playAndRecord` category and is
    /// what routes audio to the loudspeaker instead of the earpiece on a plain iPhone.
    /// `.allowBluetooth` keeps HFP/MFi hearing-aid routing working.
    /// A 300ms settle delay gives the Bluetooth stack time to complete any route
    /// switch before the synthesizer queues audio.
    private func configureSessionForPlayback() async {
        nonisolated(unsafe) let session = AVAudioSession.sharedInstance()
        do {
            try await Task.detached(priority: .userInitiated) {
                // Deactivate first to ensure a clean handoff from the now-stopped
                // recording engine, then reactivate for playback.
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                try session.setCategory(.playAndRecord,
                                        mode: .spokenAudio,
                                        options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
                try session.setActive(true)
            }.value
            // Allow Bluetooth route to settle before queuing audio.
            try? await Task.sleep(for: .milliseconds(300))
            let route = session.currentRoute.outputs.first?.portName ?? "none"
            logger.info("configureSessionForPlayback — session ready. Output route: \(route)")
        } catch {
            logger.error("configureSessionForPlayback failed: \(error)")
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let route = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "none"
            self.logger.info("didStart — TTS is speaking. Output route: \(route)")
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.logger.info("didFinish — TTS completed normally.")
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            // Deactivate the playback session so AudioSessionManager.configure() starts
            // from a clean state instead of inheriting .playback/.spokenAudio (RC1).
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.isSpeaking = false
            self.onFinish?()
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // If speak() triggered this cancel to flush a stale utterance before queuing
            // a fresh one, swallow the event entirely — isSpeaking and the timeout belong
            // to the new utterance, not to the one we just cleared.
            if self.isRestartingSpeak {
                self.logger.info("didCancel — stale utterance cleared (restarting speak); ignoring.")
                self.isRestartingSpeak = false
                return
            }
            self.logger.info("didCancel — TTS was cancelled.")
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.isSpeaking = false
            self.onCancel?()
        }
    }
}
