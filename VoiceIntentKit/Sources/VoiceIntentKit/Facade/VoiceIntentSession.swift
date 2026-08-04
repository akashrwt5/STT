// VoiceIntentSession.swift
// VoiceIntentKit
//
// THE public API. One object that turns microphone input into classified intents:
//
//     let seed = Bundle.main.url(forResource: "pack-en-v1.0.30", withExtension: nil)!
//     let session = VoiceIntentSession(configuration: .init(
//         language: .english,
//         packProvider: StaticPackProvider(language: "en", url: seed),
//         trust: myTrustPolicy))
//     Task { for await event in session.events { … } }
//     try await session.start()
//
// The pack is supplied, never discovered. See `PackProvider` for why the SDK
// does no networking and no bundle scanning.
//
// It is a headless, packaged version of the app's PVAViewModel + LiveTranscription-
// ViewModel loop — mic → transcript → 3-stage classifier → multi-turn dialog, with
// optional spoken prompts — collapsed behind a single event stream. The whole STT +
// NLU stack (coordinator, classifier, entity extractor, dialog manager, TTS) lives
// inside; the consumer never touches any of it.
//
// @MainActor because it drives AVAudioEngine / AVSpeechSynthesizer, which are main-
// actor-isolated. The heavy work (classification, embedding) happens inside the
// NLUEngine actor and Task.detached hops, so the main thread is never blocked.

import Foundation
import os.log

@MainActor
public final class VoiceIntentSession {

    // MARK: - Public

    /// Observe this to drive your UI: transcripts, dialog turns, state, and errors.
    public let events: AsyncStream<VoiceIntentEvent>

    /// Current session state (also delivered via `events`).
    public private(set) var state: VoiceSessionState = .idle {
        didSet { if state != oldValue { continuation.yield(.stateChanged(state)) } }
    }

    // MARK: - Private

    private let config: VoiceIntentConfiguration
    private let continuation: AsyncStream<VoiceIntentEvent>.Continuation
    private let coordinator = TranscriptionCoordinator()
    private let speaker = ConversationSpeaker()
    private var engine: (any ConversationEngine)?
    private var started = false
    /// True after a follow-up/confirmation, so the mic auto-restarts to hear the answer.
    private var awaitingAnswer = false
    private let logger = Logger(subsystem: "com.voiceintentkit", category: "VoiceIntentSession")

    // MARK: - Init

    /// No default configuration.
    ///
    /// `VoiceIntentSession()` used to compile, and produced an English session
    /// reading `Bundle.module` with nothing verified. There is no longer a
    /// defensible default: a session needs a pack and a trust policy, and both
    /// are the host's to choose. Requiring them is the point — the compiler now
    /// asks the question the old default answered silently.
    public init(configuration: VoiceIntentConfiguration) {
        self.config = configuration
        (self.events, self.continuation) = AsyncStream<VoiceIntentEvent>.makeStream()

        speaker.onFinish = { [weak self] in self?.handleSpeechFinished() }
        speaker.onCancel = { [weak self] in self?.handleSpeechCancelled() }
    }

    deinit { continuation.finish() }

    // MARK: - Lifecycle

    /// Builds the classifier/dialog engine (first call) and starts listening.
    /// Safe to call again after a turn completes (`state == .idle`) or after an
    /// explicit `stop()` — subsequent calls skip the engine build and just
    /// restart the mic.
    ///
    /// - Throws: a transcription error if microphone/speech permissions are denied
    ///   or the audio session cannot start.
    public func start() async throws {
        // Only re-enter from a quiescent state. `.listening` / `.thinking` /
        // `.speaking` / `.preparing` mean a session is already in flight.
        guard state == .idle || state == .stopped else { return }

        // First call: build the engine + wire delegates. Subsequent starts
        // (post-turn `.idle`, post-`stop()`) reuse the already-built engine.
        if engine == nil {
            state = .preparing
            // Leaving `.preparing` behind on a throw strands the session in a
            // state it can never leave — `start()` refuses to re-enter from
            // anything but `.idle`/`.stopped`, so the next tap would be a silent
            // no-op and the failure would look like the button not working.
            // Also surface it on `events`, because a caller watching the stream
            // should not have to also catch to learn the session is dead.
            do {
                try await prepare()
            } catch {
                state = .stopped
                continuation.yield(.error(message: "\(error)"))
                throw error
            }
        }

        started = true
        awaitingAnswer = false          // fresh start: not mid-conversation
        try await beginListening()
    }

    /// The one-time half of `start()`: locale, delegates, engine, prewarm.
    private func prepare() async throws {
        // Build the engine FIRST, before any audio setup.
        //
        // It used to come after `switchLocale`, which re-arms the recogniser's
        // prewarm internally — so a pack failure left the microphone stack warmed
        // for a session that could never run, and the only visible symptom was
        // speech-model logs followed by silence. Fail before touching hardware.
        //
        // Throws a `VoiceIntentError` if the pack is missing, unsigned, tampered
        // with, or for the wrong language — none of which may be answered by
        // quietly starting a session in a different language.
        let engine = try await buildEngine()
        self.engine = engine

        try? await coordinator.switchLocale(to: config.language.localeIdentifier)

        coordinator.delegate = self
        coordinator.silenceConfiguration = config.autoStopOnSilence ? .singleUtterance : .disabled
        coordinator.endpointArbiter = { [weak self] text in
            guard let self, let engine = self.engine else { return .complete }
            return await engine.assessSlotAnswer(text)
        }

        await engine.warmUp()
        if config.loadsSemanticRescue { await engine.loadStage3() }

        coordinator.prewarm()
    }

    /// Stops listening and speaking and releases audio resources. Safe to call anytime.
    public func stop() {
        started = false
        awaitingAnswer = false
        speaker.stop()
        coordinator.stopLiveTranscription()
        coordinator.releaseAudioSession()
        state = .stopped
    }

    /// Abandons any in-progress multi-turn conversation without stopping the session.
    public func reset() async {
        awaitingAnswer = false
        await engine?.reset()
    }

    // MARK: - Text-only classification (no microphone)

    /// Classify a single piece of text through the same pipeline, bypassing the
    /// microphone. Useful for keyboard input or testing. Returns one turn outcome.
    /// Builds the engine on first use if `start()` was never called.
    ///
    /// - Throws: a `VoiceIntentError` when the pack cannot be resolved, verified
    ///   or bound. Previously this could not fail, because failure meant English.
    public func classify(text: String) async throws -> VoiceIntentTurn {
        let active: any ConversationEngine
        if let existing = engine {
            active = existing
        } else {
            active = try await buildEngine()
            engine = active
        }
        let response = await active.handle(text)
        return Self.turn(from: response)
    }

    // MARK: - Engine construction

    /// Resolve, verify and bind this session's pack, then build the engine.
    ///
    /// Throws rather than falling back. The predecessor answered a missing or
    /// broken pack by substituting English — which is indistinguishable from
    /// success for an English user, and wrong in the user's hands for everyone
    /// else. A caller that cannot get a pack needs to know, not to be handed a
    /// session that will confidently misunderstand.
    private func buildEngine() async throws -> any ConversationEngine {
        let code = config.language.languageCode
        let url = try await config.packProvider.packURL(for: code)
        let stopwords = config.fuzzyStopwords
        let trust = config.trust

        // Off the main actor: signature verification, sha256 over every file,
        // JSON decode and a CoreML load.
        return try await Task.detached(priority: .userInitiated) {
            let pack = try BundleDataLoader.load(packAt: url, language: code, trust: trust)
            return try PackEngineFactory.makeEngine(pack: pack, stopwords: stopwords)
        }.value
    }

    // MARK: - Listening

    private func beginListening() async throws {
        // Slot answers get the unhurried window; first commands the standard one.
        coordinator.silenceConfiguration = awaitingAnswer
            ? .slotAnswer
            : (config.autoStopOnSilence ? .singleUtterance : .disabled)
        try await coordinator.startLiveTranscription()
        state = .listening
    }

    // MARK: - Turn application

    private func apply(_ response: NLUResponse, utterance: String) {
        switch response {
        case .prompt(_, let question, let filled):
            awaitingAnswer = true
            continuation.yield(.turn(.followUp(question: question, collected: filled)))
            ask(question)

        case .confirm(_, _, let question):
            awaitingAnswer = true
            continuation.yield(.turn(.confirmation(question: question)))
            ask(question)

        case .fulfill(let intent, _, let params, let message, let confidence, let rescue, let bd):
            awaitingAnswer = false
            continuation.yield(.turn(.fulfilled(
                intent: intent, slots: params, message: message,
                confidence: confidence, viaSemanticRescue: rescue,
                stages: Self.stages(from: bd))))
            announce(message)

        case .fallback(let url, let confidence, let bd):
            awaitingAnswer = false
            continuation.yield(.turn(.notUnderstood(
                fallbackURL: url, confidence: confidence,
                stages: Self.stages(from: bd))))
            finishTurnIfNeeded()

        case .interrupted(let cancelled, let inner):
            continuation.yield(.turn(.interrupted(cancelledIntent: cancelled)))
            apply(inner, utterance: utterance)   // deliver the new intent's outcome next
        }
    }

    /// Maps an NLU response to a single public turn (text-path convenience).
    private static func turn(from response: NLUResponse) -> VoiceIntentTurn {
        switch response {
        case .prompt(_, let q, let filled):           return .followUp(question: q, collected: filled)
        case .confirm(_, _, let q):                    return .confirmation(question: q)
        case .fulfill(let i, _, let p, let m, let c, let r, let bd):
            return .fulfilled(intent: i, slots: p, message: m, confidence: c,
                              viaSemanticRescue: r, stages: stages(from: bd))
        case .fallback(let url, let c, let bd):
            return .notUnderstood(fallbackURL: url, confidence: c, stages: stages(from: bd))
        case .interrupted(let cancelled, _):           return .interrupted(cancelledIntent: cancelled)
        }
    }

    /// Copies the internal 3-stage `ClassificationBreakdown` into the narrow
    /// public `VoiceIntentStages`. Kept minimal (winning stage + s2/s3 scores)
    /// so the facade's public surface stays small.
    private static func stages(from breakdown: ClassificationBreakdown?) -> VoiceIntentStages? {
        guard let breakdown else { return nil }
        return VoiceIntentStages(
            winningStage: breakdown.winningStage,
            stage2Score: breakdown.stage2?.confidence,
            stage3Score: breakdown.stage3?.confidence
        )
    }

    // MARK: - Speech (TTS)

    private func ask(_ question: String) {
        guard config.speaksPrompts else { finishTurnIfNeeded(); return }
        speakSerialized(question)
    }

    private func announce(_ message: String) {
        guard config.speaksPrompts, !message.isEmpty else { finishTurnIfNeeded(); return }
        speakSerialized(message)
    }

    /// Stops the mic (keeping the audio session active), waits for the recognizer to
    /// drain, then speaks — so the recognizer never transcribes our own TTS.
    private func speakSerialized(_ text: String) {
        state = .speaking
        coordinator.stopLiveTranscription(deactivateSession: false)
        Task { [weak self] in
            guard let self else { return }
            await self.coordinator.waitForTeardown()
            guard self.state == .speaking else { return }
            await self.speaker.speak(text, locale: self.coordinator.currentLocale)
        }
    }

    private func handleSpeechFinished() {
        state = .thinking   // brief transitional state between speaking and next action
        if awaitingAnswer {
            // Mid-conversation: listen for the user's answer.
            Task { try? await beginListening() }
        } else if !config.autoStopOnSilence {
            // Continuous mode: resume so the user can speak a new command.
            Task { try? await beginListening() }
        } else {
            // Single-utterance mode, conversation done — leave the mic off.
            state = .idle
        }
    }

    private func handleSpeechCancelled() {
        if state == .speaking { state = .idle }
    }

    /// Advance the session after a turn that did NOT go through TTS — this
    /// path is called for the `.notUnderstood` fallback and for any turn whose
    /// fulfillment message is empty. Without this, state would stay stuck on
    /// `.thinking` forever (there's no `didFinishSpeaking` callback to fire)
    /// and consumers watching `.stateChanged` for `.idle` never see it.
    private func finishTurnIfNeeded() {
        if awaitingAnswer {
            Task { try? await beginListening() }
        } else if !config.autoStopOnSilence {
            Task { try? await beginListening() }
        } else {
            state = .idle
        }
    }
}

// MARK: - TranscriptionDelegate

extension VoiceIntentSession: TranscriptionDelegate {

    public func didReceivePartialResult(_ text: String) {
        guard state != .speaking else { return }
        continuation.yield(.partialTranscript(text))
    }

    public func didReceiveFinalResult(_ text: String) {
        // Ignore audio captured while the assistant is speaking (our own TTS).
        guard state != .speaking else { return }
        continuation.yield(.finalTranscript(text))
        state = .thinking
        Task { [weak self] in
            guard let self, let engine = self.engine else { return }
            let response = await engine.handle(text)
            self.apply(response, utterance: text)
        }
    }

    public func didEncounterError(_ error: TranscriptionError) {
        continuation.yield(.error(message: String(describing: error)))
        state = .stopped
    }

    public func didChangeState(_ state: TranscriptionState) {
        // STT-internal state; surfaced only through our own higher-level state model.
    }

    public func didReachEndOfSpeech() {
        // Silence detection ended the live session; the final-result path handles
        // classification. Nothing to do here.
    }

    public func didUpdateAudioLevel(_ powerDBFS: Float) {
        // Level metering is available but not part of the minimal public surface.
    }
}
