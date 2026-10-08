// VoiceIntentSession.swift
// VoiceAIKit
//
// The main API of VoiceAIKit. One object that turns microphone input into classified
// intents (speech to text, intent classification, multi-turn dialog, optional spoken
// prompts) and delivers everything on an event stream.
//
//     let session = VoiceIntentSession(configuration: .init(
//         language: .english,
//         packProvider: StaticPackProvider(language: "en", url: seedPackURL),
//         trust: myTrustPolicy))
//     Task { for await event in session.events { … } }
//     try await session.start()
//
// The host supplies the pack through a `PackProvider`. The SDK does not download packs.
//
// It runs on the main actor because `TranscriptionCoordinator` (audio) and
// `ConversationSpeaker` (speech) do. Classification runs in the `NLUEngine` actor and
// in detached tasks, so the main thread is not blocked.

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

    /// The pack this session is running. It is `nil` until the engine is built, which
    /// happens on the first `start()` or `classify(text:)`.
    ///
    /// Use it to find out which pack handled a request. `VoiceIntentClient.activePackVersion(for:)`
    /// can report a newer pack after an OTA update, because a session keeps its pack until
    /// the next session starts.
    public private(set) var loadedPack: PackIdentity?

    // MARK: - Private

    private let config: VoiceIntentConfiguration
    private let continuation: AsyncStream<VoiceIntentEvent>.Continuation
    private let coordinator: TranscriptionCoordinator
    /// Non-nil only for `.appProvided` audio — the push target for `provideAudio(_:)`.
    private let appAudio: AppAudioInputProvider?
    private let speaker = ConversationSpeaker()
    private var engine: (any ConversationEngine)?
    /// True while the host wants the session running: set by `start()`, cleared by
    /// `stop()`. It is separate from `state` because a turn can still be in flight after
    /// `stop()`. Turn handlers check this flag so a stopped session does not speak or
    /// reopen the microphone.
    private var started = false
    /// The in-flight classification for the most recent final transcript.
    ///
    /// Stored so `stop()` can cancel it. Unowned, this task outlives `stop()`, finishes
    /// its `await`, and drives a whole turn — speaking, and reopening the microphone —
    /// after the user asked the session to stop.
    private var classifyTask: Task<Void, Never>?
    /// True after a follow-up/confirmation, so the mic auto-restarts to hear the answer.
    private var awaitingAnswer = false
    /// Generation tag for the external-TTS delivery watchdog. A fresh
    /// `awaitHostDelivery()` or a `hostDidFinishSpeaking()` bumps it so a pending timer
    /// can never advance a turn that already moved on.
    private var hostDeliveryGeneration = 0
    /// Safety net: if the host never calls `hostDidFinishSpeaking()` in external-TTS
    /// mode, advance anyway after this long instead of sticking in `.speaking` forever.
    private static let externalDeliveryTimeoutSeconds: Double = 30
    private let logger = Logger(subsystem: "com.voiceaikit", category: "VoiceIntentSession")

    // MARK: - Init

    /// Creates a session. The configuration is required: it sets the language, the pack
    /// provider and the trust policy.
    public init(configuration: VoiceIntentConfiguration) {
        self.config = configuration
        (self.events, self.continuation) = AsyncStream<VoiceIntentEvent>.makeStream()

        // Build the audio pipeline for the requested source. For `.appProvided` the
        // coordinator is told it does NOT own the AVAudioSession, and a push provider
        // is created for `provideAudio(_:)` to feed.
        //
        // The locale comes from `configuration` and is set here, when the coordinator is created.
        let locale = Locale(identifier: configuration.language.localeIdentifier)
        switch configuration.audioSource {
        case .microphone:
            self.appAudio = nil
            self.coordinator = TranscriptionCoordinator(locale: locale)
        case .appProvided(let sampleRate):
            let provider = AppAudioInputProvider(sampleRate: sampleRate)
            self.appAudio = provider
            self.coordinator = TranscriptionCoordinator(appAudioProvider: provider, locale: locale)
        }

        speaker.onFinish = { [weak self] in self?.handleSpeechFinished() }
        speaker.onCancel = { [weak self] in self?.handleSpeechCancelled() }
    }

    /// Releases the microphone and the audio session when the host drops this session
    /// without calling `stop()`.
    ///
    /// `stop()` is still the right way to end a session. This is a safety net, and it logs
    /// a warning when it is needed. It assumes one `VoiceIntentSession` at a time, because
    /// `AVAudioSession` is shared by the whole process.
    ///
    /// `coordinator` and `speaker` are captured strongly on purpose: `self` is already
    /// being destroyed, and they must stay alive until the shutdown finishes.
    ///
    /// `stopLiveTranscription()` handles a session that is live. `releaseAudioSession()`
    /// handles one that is already idle. Each returns early when there is nothing to do,
    /// so calling both is safe. In `.appProvided` mode the host owns the audio session, so
    /// `releaseAudioSession()` does nothing there. `AudioSessionManager.deinit` is a last
    /// safety net for anything these calls miss.
    deinit {
        continuation.finish()

        // `started` is still true only if the host never called `stop()`. Say so once —
        // an integrating team debugging "why is my microphone indicator still on" should
        // find the answer in Console rather than in this file.
        if started {
            logger.warning("VoiceIntentSession was deallocated without stop(). Tearing the audio stack down from deinit; call stop() to make this deterministic.")
        }

        let coordinator = self.coordinator
        let speaker = self.speaker
        Task { @MainActor in
            speaker.stop()
            coordinator.stopLiveTranscription()
            coordinator.releaseAudioSession()
        }
    }

    // MARK: - Lifecycle

    /// Starts a new conversation and begins listening.
    ///
    /// The first call also builds the engine (loads and verifies the pack). Later calls
    /// reuse it. `start()` discards any unfinished multi-turn conversation in the engine,
    /// so it always begins fresh. To resume a conversation, use `startNextListeningTurn()`.
    ///
    /// It does nothing unless `state` is `.idle` or `.stopped`.
    ///
    /// - Throws: `VoiceIntentConfigurationError` for an invalid configuration,
    ///   `VoiceIntentError` if the pack cannot be found, verified or loaded, or a
    ///   transcription error if permissions are denied or the audio session cannot start.
    ///   If building the engine fails, `state` becomes `.stopped` and an `.error` event is sent.
    public func start() async throws {
        // Fail-fast: app-owned audio owns the AVAudioSession, so the package's internal
        // TTS cannot reliably play. Refuse the combination loudly rather than dropping
        // prompts silently. The host must use external TTS (speaksPrompts == false).
        if case .appProvided = config.audioSource, config.speaksPrompts {
            throw VoiceIntentConfigurationError.internalTTSUnavailableWithAppProvidedAudio
        }

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

        // Reset the engine too, not only this object. The engine keeps its own multi-turn
        // state, and without this the next utterance after `stop()` and `start()` would be
        // treated as the answer to an old question. `start()` begins a new conversation;
        // `startNextListeningTurn()` resumes one and leaves the engine alone.
        let wasMidConversation = await engine?.isCollecting ?? false
        await engine?.reset()
        if wasMidConversation {
            logger.info("start(): discarded an abandoned multi-turn conversation the engine was still holding.")
        }

        try await beginListening()
    }

    /// Safely starts a new recognition turn from an idle state.
    ///
    /// Use this to resume the conversation loop after completing external TTS delivery
    /// (e.g. after a `.notUnderstood` fallback where the host generated and spoke an answer).
    ///
    /// This is a lightweight transition that bypasses engine setup and safely rejects
    /// calls if the session is already active.
    ///
    /// - Throws: a transcription error if the audio session cannot start.
    public func startNextListeningTurn() async throws -> Bool {
        guard state == .idle else {
            logger.warning("startNextListeningTurn() ignored: state is \(String(describing: self.state), privacy: .public), expected .idle")
            return false
        }
        logger.info("[Session] startNextListeningTurn(): Resuming listening from idle state.")
        try await beginListening()
        logger.info("startNextListeningTurn(): listening.")
        return true
    }

    /// The one-time half of `start()`: locale, delegates, engine, prewarm.
    private func prepare() async throws {
        // Build the engine first, before any audio setup, so a bad pack fails before the
        // microphone stack is prepared.
        //
        // Throws a `VoiceIntentError` if the pack is missing, unsigned, tampered with, or
        // for the wrong language. It never falls back to a different language.
        // `engine` stays a local (non-optional): `self.engine` is optional, and the
        // warm-up calls at the end of this function need the unwrapped value.
        let built = try await buildEngine()
        let engine = built.engine
        self.engine = engine
        self.loadedPack = built.identity

        // Not `try?`: this throws `TranscriptionError.localeNotSupported` when the device has
        // no speech model for the requested locale. The host needs to be told, because
        // otherwise the pack's language would be heard through a recogniser set to a
        // different language.
        try await coordinator.switchLocale(to: config.language.localeIdentifier)

        coordinator.delegate = self
        coordinator.silenceConfiguration = config.autoStopOnSilence
            ? (config.commandSilence ?? .singleUtterance)
            : .disabled
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
        markNotRunning()
        speaker.stop()
        coordinator.stopLiveTranscription()
        coordinator.releaseAudioSession()
        state = .stopped
    }

    /// Marks the session as no longer running. It is called from `stop()`,
    /// `didEncounterError(_:)`, and when the microphone cannot be reopened for the next
    /// turn. Every path that ends in `.stopped` must call it, so an in-flight turn cannot
    /// finish later and reopen the microphone.
    ///
    /// It does not touch audio, TTS or `state`. Each caller does that itself.
    private func markNotRunning() {
        started = false
        awaitingAnswer = false
        // Cancelling is the optimisation; `started` is the correctness. A task already
        // past its last cancellation point is stopped by the guards, not by this line.
        classifyTask?.cancel()
        classifyTask = nil
    }

    /// Abandons any in-progress multi-turn conversation without stopping the session.
    public func reset() async {
        awaitingAnswer = false
        await engine?.reset()
    }

    // MARK: - App-provided audio

    /// Feeds one chunk of raw **Int16 mono** PCM (at the sample rate given in
    /// `.appProvided`) into the recognition pipeline.
    ///
    /// No-op unless the session was created with `audioSource == .appProvided`. Audio
    /// pushed while the session is not `.listening` is dropped, so trailing audio from
    /// one turn cannot bleed into the next. Feed audio only while `state == .listening`
    /// (observe the `.stateChanged` event).
    ///
    /// This method is main-actor isolated, like the rest of the session. From other
    /// threads, call it with `await`.
    public func provideAudio(_ data: Data) {
        appAudio?.enqueue(data)
    }

    // MARK: - External TTS

    /// Call from the host after it finishes delivering a prompt or result (speaking or
    /// showing it) in external-TTS mode (`speaksPrompts == false`). This advances the
    /// conversation: resume listening for the user's answer, restart for the next
    /// command (continuous mode), or go idle.
    ///
    /// Required in external-TTS mode — the session deliberately does NOT reopen the mic
    /// after emitting a prompt until you signal here, so your own speech is never
    /// captured as the user's answer and the mic never reopens before the user has heard
    /// the prompt. Without this call, VoiceAIKit moves on after 30 seconds instead of
    /// staying stuck in `.speaking`.
    ///
    /// No-op when the package's internal TTS is active (it advances itself), or when the
    /// session is not currently awaiting host delivery.
    public func hostDidFinishSpeaking() {
        guard !config.speaksPrompts else { return }   // internal TTS drives its own advance
        guard state == .speaking else { return }       // only valid while delivering a prompt
        hostDeliveryGeneration &+= 1                    // invalidate the pending watchdog
        handleTurnAdvance()
    }

    // MARK: - Text-only classification (no microphone)

    /// Classify a single piece of text through the same pipeline, bypassing the
    /// microphone. Useful for keyboard input or testing. Returns one turn outcome.
    /// Builds the engine on first use if `start()` was never called.
    ///
    /// - Throws: a `VoiceIntentError` when the pack cannot be resolved, verified
    ///   or bound.
    public func classify(text: String) async throws -> VoiceIntentTurn {
        let active: any ConversationEngine
        if let existing = engine {
            active = existing
        } else {
            let built = try await buildEngine()
            active = built.engine
            engine = active
            loadedPack = built.identity
        }
        let response = await active.handle(text)
        return Self.turn(from: response)
    }

    // MARK: - Engine construction

    /// Loads and verifies the pack for the configured language and builds the engine.
    /// It throws if the pack cannot be found, verified or loaded. It never falls back to
    /// a different pack.
    private func buildEngine() async throws -> (engine: any ConversationEngine, identity: PackIdentity) {
        let code = config.language.languageCode
        let url = try await config.packProvider.packURL(for: code)
        // These are OPTIONAL overrides. When nil (the normal case) `PackEngineFactory`
        // sources both from the pack's own lexicon — the single place that default lives,
        // so it stays consistent whether the engine is built here or via `classify(text:)`.
        let configStopwords = config.fuzzyStopwords
        let configTrailing = config.trailingFunctionWords
        let trust = config.trust
        // A development override never reaches a session that refuses
        // development packs, which is how a release build is configured.
        let fmOverride = trust.refusesDevelopmentPacks ? nil : config.foundationModelOverride
        // The same locale the speech recogniser uses, so the language model is
        // told the region as well as the language ("de_DE", not "de").
        let locale = Locale(identifier: config.language.localeIdentifier)
        if config.foundationModelOverride != nil, fmOverride == nil {
            logger.notice("foundationModelOverride ignored: the trust policy refuses development packs")
        }

        // Off the main actor: signature verification, sha256 over every file,
        // JSON decode and a CoreML load.
        return try await Task.detached(priority: .userInitiated) {
            let pack = try BundleDataLoader.load(packAt: url, language: code, trust: trust)
            let engine = try PackEngineFactory.makeEngine(
                pack: pack, stopwords: configStopwords, trailingFunctionWords: configTrailing,
                foundationModelOverride: fmOverride,
                locale: locale
            )
            // Identity is captured from the pack that was just VERIFIED and LOADED,
            // inside the same closure. Reading `bundle.json` again afterwards would
            // reintroduce the gap this property exists to close.
            return (engine, PackIdentity(pack.manifest))
        }.value
    }

    // MARK: - Listening

    private func beginListening() async throws {
        // No `started` check before starting the microphone, because
        // `startNextListeningTurn()` calls this directly. The mic-reopen paths are closed
        // at `apply()` and `handleTurnAdvance()` instead, which is where a stopped
        // session's turn actually leaks through.
        // Slot answers get the unhurried window; first commands the standard one.
        coordinator.silenceConfiguration = awaitingAnswer
            ? (config.slotAnswerSilence ?? .slotAnswer)
            : (config.autoStopOnSilence ? (config.commandSilence ?? .singleUtterance) : .disabled)
        try await coordinator.startLiveTranscription()
        // `stop()` can land while the audio stack is starting — it is several tens of
        // milliseconds of permissions, session configuration and analyzer start. Without
        // this the microphone comes up AFTER the user stopped the session and `state` is
        // driven back to `.listening` on top of `.stopped`. Undo rather than ignore: the
        // mic is genuinely running by this point.
        guard started else {
            logger.info("Microphone came up after the session was stopped — tearing it back down.")
            coordinator.stopLiveTranscription()
            return
        }
        state = .listening
    }

    // MARK: - Turn application

    private func apply(_ response: NLUResponse, utterance: String) {
        // The single choke point for a turn's outcome, and therefore the place to
        // refuse one belonging to a session the host has stopped. Every branch below
        // has a side effect that must not happen after `stop()`: speaking aloud,
        // arming the external-TTS watchdog, setting `awaitingAnswer` (which would leak
        // into the next `start()`), or reopening the microphone.
        guard started else {
            logger.info("Discarding a turn outcome: the session was stopped while it was in flight.")
            return
        }
        switch response {
        case .prompt(let intent, let question, let filled):
            awaitingAnswer = true
            continuation.yield(.turn(.followUp(intent: intent, question: question, collected: filled)))
            ask(question)

        case .confirm(let intent, _, let question, let filled):
            awaitingAnswer = true
            continuation.yield(.turn(.confirmation(intent: intent, question: question, collected: filled)))
            ask(question)

        case .fulfill(let intent, _, let params, let message, let confidence, let rescue, let bd, _):
            awaitingAnswer = false
            continuation.yield(.turn(.fulfilled(
                intent: intent, slots: params, message: message,
                confidence: confidence, viaSemanticRescue: rescue,
                stages: Self.stages(from: bd))))
            announce(message)

        case .fallback(let intent, let confidence, let bd):
            awaitingAnswer = false
            continuation.yield(.turn(.notUnderstood(
                intent: intent, confidence: confidence,
                stages: Self.stages(from: bd))))
            // Fallbacks are fully delegated to the host (GenAI/Wolfram). We do not wait for
            // TTS delivery here. Transition to idle; the host will explicitly resume when ready.
            handleTurnAdvance()

        case .interrupted(let cancelled, let inner):
            continuation.yield(.turn(.interrupted(cancelledIntent: cancelled)))
            apply(inner, utterance: utterance)   // deliver the new intent's outcome next
        }
    }

    /// Maps an NLU response to a single public turn (text-path convenience).
    private static func turn(from response: NLUResponse) -> VoiceIntentTurn {
        switch response {
        case .prompt(let intent, let q, let filled):           return .followUp(intent: intent, question: q, collected: filled)
        case .confirm(let intent, _, let q, let filled):       return .confirmation(intent: intent, question: q, collected: filled)
        case .fulfill(let i, _, let p, let m, let c, let r, let bd, _):
            return .fulfilled(intent: i, slots: p, message: m, confidence: c,
                              viaSemanticRescue: r, stages: stages(from: bd))
        case .fallback(let intent, let c, let bd):
            return .notUnderstood(intent: intent, confidence: c, stages: stages(from: bd))
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
        if config.speaksPrompts {
            speakSerialized(question)          // internal TTS: onFinish advances the turn
        } else {
            awaitHostDelivery()                // external TTS: wait for hostDidFinishSpeaking()
        }
    }

    private func announce(_ message: String) {
        if config.speaksPrompts {
            guard !message.isEmpty else { finishTurnIfNeeded(); return }
            speakSerialized(message)
        } else {
            awaitHostDelivery()                // external TTS: host delivers the result
        }
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
        handleTurnAdvance()
    }

    /// The single place that decides what happens once a turn's prompt/result has been
    /// delivered: resume listening for the answer, restart for the next command
    /// (continuous mode), or go idle (single-utterance, conversation done). Driven by
    /// the internal TTS finishing (`handleSpeechFinished`), by `hostDidFinishSpeaking()`
    /// in external-TTS mode, or immediately for turns with nothing to speak.
    private func handleTurnAdvance() {
        // Reached from the external-TTS watchdog too, which fires up to 30s later and
        // does not pass through `apply()`. Note the early return rather than falling
        // to the `.idle` branch below: a stopped session must stay `.stopped`.
        guard started else { return }
        if awaitingAnswer {
            // Mid-conversation: listen for the user's answer.
            resumeListening()
        } else if !config.autoStopOnSilence {
            // Continuous mode: resume so the user can speak a new command.
            resumeListening()
        } else {
            // Single-utterance mode, conversation done — leave the mic off.
            state = .idle
        }
    }

    /// Reopens the microphone for the next turn. If that fails, the session stops and an
    /// `.error` event is sent, so the host is not left waiting in `.thinking`.
    ///
    /// The task is not stored and not cancelled. Cancelling `startLiveTranscription()` while
    /// it is starting can leave the coordinator in `.preparingAudio`, which `isActive` does
    /// not count. The `started` flag is what stops an old turn from doing anything.
    private func resumeListening() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.beginListening()
            } catch is CancellationError {
                return
            } catch {
                // `stop()` may have landed while the audio stack was starting. A session
                // the host has already given up on does not need an error report, and
                // must not be dragged out of `.stopped`.
                guard self.started else { return }

                self.logger.error("Could not reopen the microphone for the next turn: \(error.localizedDescription, privacy: .public)")

                // `startLiveTranscription()` has no teardown on its throw path, so the
                // coordinator can be sitting in `.preparingAudio` holding a configured
                // audio session. Tear it down rather than leave the session dead with the
                // route still taken.
                self.coordinator.stopLiveTranscription()

                // Same path as `stop()` and `didEncounterError(_:)`: use `markNotRunning()` so a
                // pending turn cannot reopen the microphone.
                self.markNotRunning()
                self.continuation.yield(.error(message: String(describing: error)))
                self.state = .stopped
            }
        }
    }

    /// External-TTS hold: the turn's text has been emitted on `events`; the host is now
    /// delivering it (speaking / showing). Stay here — do NOT reopen the mic or go idle
    /// — until the host calls `hostDidFinishSpeaking()`. This is what keeps the host's
    /// own speech from being captured as the user's answer, and keeps the mic from
    /// reopening before the user has heard the prompt.
    private func awaitHostDelivery() {
        state = .speaking
        // Arm the watchdog so a host that forgets to signal can't wedge the session.
        hostDeliveryGeneration &+= 1
        let generation = hostDeliveryGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.externalDeliveryTimeoutSeconds))
            guard let self,
                  generation == self.hostDeliveryGeneration,
                  self.state == .speaking else { return }
            self.logger.warning("External-TTS watchdog: hostDidFinishSpeaking() not called within \(Self.externalDeliveryTimeoutSeconds)s — advancing to avoid a stuck session.")
            self.handleTurnAdvance()
        }
    }

    private func handleSpeechCancelled() {
        if state == .speaking { state = .idle }
    }

    /// Advances the session after a turn whose spoken message is empty, so there is no
    /// `didFinishSpeaking` callback to wait for. Without this, `state` would stay on
    /// `.thinking` and consumers watching `.stateChanged` for `.idle` would never see it.
    private func finishTurnIfNeeded() {
        handleTurnAdvance()
    }
}

// MARK: - TranscriptionDelegate

/// Internal conformance: `TranscriptionDelegate` is not public, so the session does not
/// expose these callbacks. The host gets the same information on `events`.
extension VoiceIntentSession: TranscriptionDelegate {

    func didReceivePartialResult(_ text: String) {
        guard state != .speaking else { return }
        continuation.yield(.partialTranscript(text))
    }

    func didReceiveFinalResult(_ text: String) {
        // Ignore audio captured while the assistant is speaking (our own TTS).
        guard state != .speaking else { return }
        // A final result can still be in flight from the coordinator when `stop()` runs.
        // Refusing it here is cheaper than classifying it and discarding the outcome,
        // and it keeps `.thinking` and `.finalTranscript` from being reported for a
        // session the host has already stopped.
        guard started else {
            logger.info("Discarding a final transcript: the session is not started.")
            return
        }
        continuation.yield(.finalTranscript(text))
        state = .thinking
        classifyTask?.cancel()
        classifyTask = Task { [weak self] in
            guard let self, let engine = self.engine else { return }
            let response = await engine.handle(text)
            // Re-check AFTER the suspension point. `stop()` may have run while the
            // engine was classifying, and applying a turn to a stopped session is what
            // reopened the microphone.
            guard !Task.isCancelled, self.started else { return }
            self.apply(response, utterance: text)
        }
    }

    func didEncounterError(_ error: TranscriptionError) {
        continuation.yield(.error(message: String(describing: error)))
        // Both callers of this are fatal: the recognizer failed (`TranscriptionCoordinator`
        // .recognitionService(_:didFailWith:) — it has already gone `.failed`, stopped the
        // provider and torn down the audio session), or the microphone could not be
        // resumed after an interruption. `state = .stopped` below already says the session
        // is over; this makes the flag agree with it, so an in-flight turn cannot finish
        // and reopen the microphone. To recover, the host observes `.error` and calls
        // `start()` again, which is allowed from `.stopped` and sets `started` back to true.
        markNotRunning()
        state = .stopped
    }

    func didChangeState(_ state: TranscriptionState) {
        // STT-internal state; surfaced only through our own higher-level state model.
    }

    func didReachEndOfSpeech() {
        // Silence detection ended the live session; the final-result path handles
        // classification. Nothing to do here.
    }

    func didUpdateAudioLevel(_ powerDBFS: Float) {
        // Level metering is available but not part of the minimal public surface.
    }
}
