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

    // `var` so it can be recreated when the watchdog detects a zombie state.
    private var synthesizer = AVSpeechSynthesizer()
    private let logger = Logger(subsystem: "com.stt.module", category: "ConversationSpeaker")

    /// Called on the main actor when an utterance finishes *normally*. This is the
    /// signal to auto-resume listening for the user's answer.
    public var onFinish: (() -> Void)?

    /// Called on the main actor when speech is cancelled — either by an explicit `stop()`
    /// or by an external interruption (phone call, system audio). Does NOT auto-resume
    /// listening; it only lets the owner clear its own speaking state so input is no
    /// longer dropped forever after an interrupted utterance.
    public var onCancel: (() -> Void)?

    public private(set) var isSpeaking = false

    // MARK: - Restart-speak state

    /// Set to `true` when `speak()` calls `stopSpeaking()` to clear a stale utterance
    /// before queuing a new one. While true, the resulting `didCancel` callback is
    /// suppressed (it belongs to the old utterance, not the one we're about to play).
    private var isRestartingSpeak = false

    /// Text/locale stored when `speak()` defers because the synthesizer is still active.
    /// Consumed by `didCancel` (normal path) or the cancel watchdog (zombie path).
    private var pendingSpeakText: String?
    private var pendingSpeakLocale: Locale?

    /// Waits up to 500ms for `didCancel` to confirm the old utterance stopped.
    /// If it never arrives (zombie synthesizer), recreates the synthesizer and
    /// executes the pending speak directly.
    private var cancelWatchdogTask: Task<Void, Never>?

    // MARK: - Safety timeout

    /// Cancels the in-flight safety timeout when a delegate callback fires first.
    private var timeoutTask: Task<Void, Never>?

    /// Maximum seconds to wait for a delegate callback before force-resetting state.
    private static let timeoutSeconds: Double = 8

    // MARK: - Init

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Speaks `text`. If the synthesizer is already active, defers until the current
    /// utterance is fully stopped (confirmed by `didCancel`) before configuring the
    /// session and queueing the new one. This prevents `setActive(false)` from racing
    /// with an in-progress stop, which leaves the synthesizer in a zombie state where
    /// `isSpeaking` is stuck as `true` and no delegate callbacks ever arrive.
    public func speak(_ text: String, locale: Locale) {
        let session = AVAudioSession.sharedInstance()
        let routeName = session.currentRoute.outputs.first?.portName ?? "none"
        let routeType = session.currentRoute.outputs.first?.portType.rawValue ?? "none"
        logger.info("speak() — route: \(routeName) (\(routeType)), category: \(session.category.rawValue)")

        if synthesizer.isSpeaking || synthesizer.isPaused {
            logger.warning("speak() — synthesizer already active; deferring until cancel confirms.")
            pendingSpeakText = text
            pendingSpeakLocale = locale
            isRestartingSpeak = true
            synthesizer.stopSpeaking(at: .immediate)
            startCancelWatchdog()
            return
        }

        executeSpeak(text: text, locale: locale)
    }

    /// Stops any in-progress speech immediately. Clears all deferred-speak state so
    /// a pending restart does not fire after an explicit stop.
    public func stop() {
        cancelWatchdogTask?.cancel()
        cancelWatchdogTask = nil
        pendingSpeakText = nil
        pendingSpeakLocale = nil
        isRestartingSpeak = false
        timeoutTask?.cancel()
        timeoutTask = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    // MARK: - Private

    /// Configures the session and queues the utterance. Called after any stale utterance
    /// is confirmed stopped (or the synthesizer has been recreated by the watchdog).
    private func executeSpeak(text: String, locale: Locale) {
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

    /// Waits 500ms for `didCancel` to confirm the old utterance stopped. If it never
    /// arrives (zombie synthesizer — audio session was killed before the stop completed),
    /// recreates `AVSpeechSynthesizer` from scratch and executes the pending speak.
    private func startCancelWatchdog() {
        cancelWatchdogTask?.cancel()
        cancelWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            guard self.isRestartingSpeak else { return } // didCancel already fired — nothing to do
            self.logger.warning("cancelWatchdog: didCancel never arrived in 500ms — recreating synthesizer.")
            self.isRestartingSpeak = false
            self.cancelWatchdogTask = nil
            // Detach the zombie synthesizer and replace it with a clean instance.
            self.synthesizer.delegate = nil
            let fresh = AVSpeechSynthesizer()
            fresh.delegate = self
            self.synthesizer = fresh
            guard let text = self.pendingSpeakText, let locale = self.pendingSpeakLocale else { return }
            self.pendingSpeakText = nil
            self.pendingSpeakLocale = nil
            self.executeSpeak(text: text, locale: locale)
        }
    }

    /// Schedules a watchdog that force-resets speaking state if no delegate callback
    /// arrives within `timeoutSeconds`. Guards against any TTS failure mode where
    /// didFinish/didCancel is silently swallowed.
    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
            guard !Task.isCancelled, let self, self.isSpeaking else { return }
            self.logger.warning("TTS safety timeout fired (\(Self.timeoutSeconds)s) — didFinish/didCancel never received. Force-resetting isSpeaking.")
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.isSpeaking = false
            self.timeoutTask = nil
            self.onCancel?()
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
            guard self.isSpeaking else { return } // stop() already handled this
            self.logger.info("didFinish — TTS completed normally.")
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.isSpeaking = false
            self.onFinish?()
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.isRestartingSpeak {
                // This cancel belongs to the stale utterance we cleared in speak().
                // Cancel the watchdog (it's no longer needed) and execute the pending speak.
                self.logger.info("didCancel — stale utterance cleared; executing pending speak.")
                self.isRestartingSpeak = false
                self.cancelWatchdogTask?.cancel()
                self.cancelWatchdogTask = nil
                if let text = self.pendingSpeakText, let locale = self.pendingSpeakLocale {
                    self.pendingSpeakText = nil
                    self.pendingSpeakLocale = nil
                    self.executeSpeak(text: text, locale: locale)
                }
                return
            }
            guard self.isSpeaking else { return } // stop() already handled this
            self.logger.info("didCancel — TTS was cancelled.")
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.isSpeaking = false
            self.onCancel?()
        }
    }
}
