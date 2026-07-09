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

    /// Serial queue for the synchronous speech-daemon bridges (`AVSpeechSynthesisVoice`
    /// lookup and `speak(_:)`). Serial (not the global concurrent pool) so the voice
    /// cache below is accessed race-free without a lock.
    private static let speechQueue = DispatchQueue(label: "com.voiceintentkit.tts", qos: .userInitiated)
    /// Caches resolved voices per locale identifier. `AVSpeechSynthesisVoice(language:)`
    /// dispatches into the speech daemon and its first call is expensive — paying that
    /// on every prompt added avoidable latency each turn. Only touched on `speechQueue`.
    nonisolated(unsafe) private static var voiceCache: [String: AVSpeechSynthesisVoice] = [:]

    // Latency instrumentation (logging only — no behaviour change). `requestedAt`
    // is the moment the final STT result arrived (passed in by the view model) so
    // `didStart` can report the full "user stopped talking → first TTS audio"
    // delay. Filter Console.app / `log stream` by subsystem com.voiceintentkit,
    // category Latency.
    private static let latencyLog = Logger(subsystem: "com.voiceintentkit", category: "Latency")
    private let logger = Logger(subsystem: "com.voiceintentkit", category: "ConversationSpeaker")
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

    /// Speaks `text` on the already-active shared audio session.
    ///
    /// The session is owned by `AudioSessionManager` (a single `.playAndRecord`
    /// configuration shared by mic and TTS) and is guaranteed active here: the live
    /// TTS handoff stops the mic with `deactivateSession: false`, so the session
    /// stays up across the recogniser→synthesiser switch.
    ///
    /// `AVSpeechSynthesisVoice(language:)` and `AVSpeechSynthesizer.speak(_:)` both
    /// dispatch_sync into the speech daemon, which the Swift runtime flags as
    /// `unsafeForcedSync` from any Swift concurrency context — including `Task.detached`,
    /// which leaves the task tree but still runs on the cooperative thread pool. We
    /// hop onto a GCD background queue (genuinely outside the Swift concurrency
    /// executor) via a continuation so the synchronous bridge runs where libdispatch
    /// is happy. The watchdog is armed back on the main actor afterwards so
    /// generation bookkeeping stays consistent.
    ///
    /// - Parameter requestedAt: optional `CFAbsoluteTimeGetCurrent()` captured when
    ///   the triggering STT result arrived, used only to log end-to-end latency.
    public func speak(_ text: String, locale: Locale, requestedAt: CFAbsoluteTime? = nil) async {
        self.requestedAt = requestedAt

        speakGeneration &+= 1
        let generation = speakGeneration
        didStartCurrentUtterance = false
        isSpeaking = true

        let identifier = locale.identifier
        nonisolated(unsafe) let synth = synthesizer
        let voiceStart = CFAbsoluteTimeGetCurrent()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.speechQueue.async {
                let utterance = AVSpeechUtterance(string: text)
                // Voice lookup dispatches into the speech daemon — cache per locale so
                // only the first prompt of a conversation pays for it.
                if let cached = Self.voiceCache[identifier] {
                    utterance.voice = cached
                } else if let voice = AVSpeechSynthesisVoice(language: identifier)
                            ?? AVSpeechSynthesisVoice(language: "en-US") {
                    Self.voiceCache[identifier] = voice
                    utterance.voice = voice
                }
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                // No post-utterance delay: it added a flat 100ms between the prompt
                // ending and `didFinish` → mic restart on every conversation turn.
                utterance.postUtteranceDelay = 0
                synth.speak(utterance)
                continuation.resume()
            }
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - voiceStart) * 1000
        Self.latencyLog.info("speak() voiceLoad+enqueue=\(elapsedMs, format: .fixed(precision: 1))ms")
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

    deinit {
        print("[Deinit] ConversationSpeaker")
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
