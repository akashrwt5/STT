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
    /// True while the mic session is starting up (permissions → model load → analyzer
    /// creation). Prevents double-tap from cancelling an in-flight setup, and lets the
    /// UI show a "connecting…" state so the user knows the tap registered.
    public private(set) var isStarting: Bool = false
    public private(set) var audioLevel: Float = 0.0
    public private(set) var currentLocale: Locale
    public private(set) var audioSource: String = "iPhone Mic"
    public private(set) var results: [TranscriptionResult] = []
    public private(set) var error: TranscriptionError?
    public private(set) var transcriptionState: TranscriptionState = .idle

    /// When the NLU engine needs more information (e.g. "When should I remind you?"),
    /// this holds the follow-up question to surface. `nil` when not mid-conversation.
    public private(set) var pendingQuestion: String?
    /// Slot values collected so far during a multi-turn exchange, for display.
    public private(set) var collectedSlots: [String: String] = [:]
    /// True while the assistant is speaking a follow-up question or fulfillment.
    public private(set) var isSpeaking: Bool = false
    /// When enabled, follow-up questions are spoken aloud and the mic auto-restarts
    /// to capture the user's answer (hands-free conversation).
    public var voiceConversationEnabled: Bool = true

    /// When `true`, the session automatically stops after the user stops speaking
    /// (single-utterance mode). When `false`, it runs until the user taps stop
    /// (continuous captioning). Mirrors the coordinator's `silenceConfiguration`.
    public var autoStopOnSilence: Bool = false {
        didSet {
            coordinator.silenceConfiguration = autoStopOnSilence ? .singleUtterance : .disabled
        }
    }

    // MARK: - Private

    private let coordinator: TranscriptionCoordinator
    // Builds the variant-appropriate engine on demand. Injected so the ViewModel
    // never names a concrete classifier/engine type — the variant is decided
    // upstream (PVAViewModel → factory) and this layer stays variant-agnostic.
    private let factory: any NLUEngineFactory
    // @ObservationIgnored: keeps it a real stored property (the @Observable macro
    // turns tracked vars into computed ones); nlu never drives UI.
    // Initialized in activate() on the @State-retained instance (not in init, which
    // runs on throwaway view models SwiftUI creates on every parent re-render).
    @ObservationIgnored private var nlu: (any ConversationEngine)?
    /// In-flight engine construction. Engine building loads CoreML models and
    /// parses a multi-MB weights JSON — it runs on a background task so the PVA
    /// sheet presents instantly instead of freezing mid-animation on first open.
    /// Consumers that need the engine await this first (`awaitEngineReady`).
    @ObservationIgnored private var engineBuildTask: Task<Void, Never>?
    private let speaker = ConversationSpeaker()
    /// Accumulates the spoken text across a multi-turn exchange so the final card
    /// shows the complete phrase (e.g. "remind me" + "take medication" + "tomorrow").
    private var conversationTranscripts: [String] = []
    private var recordingTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.stt.module", category: "LiveTranscriptionViewModel")
    /// Per-stage TTS latency timings. Filter Console.app / `log stream` by
    /// subsystem com.stt.module, category Latency. Logging only — no behaviour change.
    private let latencyLog = Logger(subsystem: "com.stt.module", category: "Latency")

    // MARK: - Init

    public init(coordinator: TranscriptionCoordinator, factory: any NLUEngineFactory) {
        self.coordinator = coordinator
        self.factory = factory
        self.currentLocale = coordinator.currentLocale
        // NOTE: delegate is intentionally NOT set here. `LiveTranscriptionView.init`
        // runs on every parent re-render and eagerly constructs a throwaway view model
        // (SwiftUI keeps only the first `@State` instance). If we set the delegate in
        // `init`, each throwaway instance would steal `coordinator.delegate`, leaving
        // the *displayed* view model unsubscribed — and no transcript on screen.
        // Wiring happens in `activate()`, called from the View's `.onAppear`, which
        // runs on the retained instance.
    }

    // MARK: - Public API

    /// Wires this view model as the coordinator's delegate. Call from `.onAppear` so it
    /// runs on the `@State`-retained instance, not a transient one from a re-render.
    public func activate() {
        coordinator.delegate = self
        currentLocale = coordinator.currentLocale
        audioSource = coordinator.currentRoute.name
        coordinator.silenceConfiguration = autoStopOnSilence ? .singleUtterance : .disabled
        speaker.onFinish = { [weak self] in self?.handleSpeechFinished() }
        speaker.onCancel = { [weak self] in self?.handleSpeechCancelled() }

        // Content-aware endpointing: let the NLU judge whether the stable transcript
        // is a finished answer to the awaited slot. Unverifiable free text ("drink…")
        // and incomplete answers ("tomorrow" with no time) extend the endpoint
        // window instead of committing the turn mid-thought.
        coordinator.endpointArbiter = { [weak self] text in
            guard let self, let nlu = self.nlu else { return .complete }
            return await nlu.assessSlotAnswer(text)
        }

        // Guard on the build task too: the engine now constructs asynchronously,
        // so `nlu` stays nil while a build is in flight — a second onAppear must
        // not start a competing build.
        if nlu == nil && engineBuildTask == nil {
            rebuildEngine()
        }

        // Pre-load the Apple speech model (locale resolve → asset install/reserve →
        // SpeechTranscriber + SpeechAnalyzer creation) in the background so the first
        // mic tap is instant instead of waiting several seconds for model setup.
        coordinator.prewarm()
    }

    /// Builds the NLU engine for the currently-active locale's language and warms it up.
    /// Called on activation and after a locale switch so the engine's localized prompts,
    /// word-lists, and entity data always match the language the user is speaking. The
    /// language tag is the ASR locale's language code (e.g. "fr", "de", "da"); unknown or
    /// English locales fall back to "en", which the factory maps to identical-to-today
    /// English behavior.
    private func rebuildEngine() {
        let langTag = currentLocale.language.languageCode?.identifier ?? "en"
        let factory = self.factory
        engineBuildTask?.cancel()
        nlu = nil
        engineBuildTask = Task(priority: .userInitiated) { [weak self] in
            // Construct OFF the main actor: classifier init synchronously loads the
            // CoreML model and JSON-parses the full weights file (incl. the 5–25 MB
            // coef matrix). On the main thread this froze the PVA sheet's
            // presentation animation on first open.
            let engine = await Task.detached(priority: .userInitiated) {
                factory.makeEngine(language: langTag)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.nlu = engine
            // warmUp is called on the engine (not a separate classifier ref):
            // ConversationEngine.warmUp() delegates to the classifier, so there is
            // a single warm-up entry point regardless of variant.
            Task(priority: .userInitiated) { await engine.warmUp() }
        }
    }

    /// Suspends until the NLU engine (re)build in flight has finished. The engine
    /// is ready long before the user can finish an utterance, but consumers must
    /// await rather than assume — a fast first utterance must not be dropped.
    public func awaitEngineReady() async {
        await engineBuildTask?.value
    }

    /// Called when the assistant finishes speaking normally. Decides whether to resume.
    private func handleSpeechFinished() {
        isSpeaking = false
        guard voiceConversationEnabled else { return }

        if pendingQuestion != nil {
            // Mid-conversation: always restart to capture the user's answer.
            startRecording()
        } else if !autoStopOnSilence {
            // Conversation just completed in continuous mode — resume so the user can
            // speak a new intent without tapping the mic again.
            startRecording()
        }
        // In single-utterance (silence-detection) mode after fulfillment: leave the
        // mic off. The coordinator already stopped when silence was detected; auto-
        // restarting here would loop indefinitely.
    }

    /// Called when speech is cancelled (explicit stop or external interruption like a
    /// phone call). Only clears speaking state — never auto-resumes — so that input is
    /// no longer dropped by the `isSpeaking` guard once speech is gone.
    private func handleSpeechCancelled() {
        isSpeaking = false
    }

    /// Toggles recording on/off.
    public func toggleRecording() {
        if isListening { stopRecording() }
        else if !isStarting { startRecording() }
        // isStarting == true: tap during setup is silently ignored — the UI already
        // shows a "connecting…" indicator so the user knows the first tap landed.
    }

    /// Switches the active transcription locale and restarts the session if needed.
    public func switchLocale(_ identifier: String) {
        Task {
            do {
                if isListening { stopRecording() }
                try await coordinator.switchLocale(to: identifier)
                currentLocale = coordinator.currentLocale
                // Rebuild the NLU engine in the new language: localized prompts,
                // yes/no, enum synonyms, and entity data are all language-specific.
                // TTS already follows currentLocale live. If we left the old engine
                // in place, a fr/de/da user would get English NLU after switching.
                rebuildEngine()
            } catch {
                self.error = error as? TranscriptionError
            }
        }
    }

    /// Loads Stage 3 (MiniLM semantic rescue) on the NLU's classifier.
    /// After this call, low-confidence Stage 2 results are rescued by Stage 3.
    public func loadStage3() async {
        await awaitEngineReady()
        await nlu?.loadStage3()
    }

    /// Releases Stage 3 refs. Stage 3 is skipped on future classifications.
    public func releaseStage3() async {
        await nlu?.releaseStage3()
    }

    /// Clears all stored final results and the current transcript.
    public func clearResults() {
        results.removeAll()
        transcript = ""
        pendingQuestion = nil
        collectedSlots = [:]
        conversationTranscripts.removeAll()
        isSpeaking = false
        speaker.stop()
        Task { [nlu] in await nlu?.reset() }
    }

    /// Stops recording and TTS immediately. Call before releasing this instance
    /// (e.g., from PVASheetView.onDisappear) so in-flight tasks can cancel cleanly.
    public func teardown() {
        engineBuildTask?.cancel()
        if isListening || isStarting {
            stopRecording()
        } else {
            // The conversation flow keeps the audio session active across
            // recognizer↔TTS handoffs even after the mic stops — release it now
            // so it doesn't outlive this screen.
            coordinator.releaseAudioSession()
        }
        speaker.stop()
        isSpeaking = false
    }

    // MARK: - Private

    private func startRecording() {
        // Context-dependent endpointing: answers to a follow-up question use the
        // unhurried `.slotAnswer` window (1.5s) — people routinely pause mid-answer
        // ("drink… water"), and clipping the answer costs a whole extra turn.
        // First commands keep the standard 1.0s window. Applies even in continuous
        // mode: a slot answer turn should always endpoint.
        if pendingQuestion != nil {
            coordinator.silenceConfiguration = .slotAnswer
        } else {
            coordinator.silenceConfiguration = autoStopOnSilence ? .singleUtterance : .disabled
        }

        error = nil
        isStarting = true
        recordingTask = Task {
            do {
                try await coordinator.startLiveTranscription()
                isStarting  = false
                isListening = true
            } catch let err as TranscriptionError {
                isStarting  = false
                isListening = false
                self.error  = err
            } catch {
                isStarting  = false
                isListening = false
                self.error  = .analyzerFailed(error)
            }
        }
    }

    /// - Parameter deactivateSession: forwarded to the coordinator. The TTS handoff
    ///   passes `false` so the shared audio session stays active and the prompt can be
    ///   spoken immediately, without a deactivate/re-activate round-trip.
    private func stopRecording(deactivateSession: Bool = true) {
        recordingTask?.cancel()
        recordingTask = nil
        isStarting  = false
        isListening = false
        coordinator.stopLiveTranscription(deactivateSession: deactivateSession)
        audioLevel = 0.0
    }

    deinit {
        print("[Deinit] LiveTranscriptionViewModel")
    }
}

// MARK: - TranscriptionDelegate

extension LiveTranscriptionViewModel: TranscriptionDelegate {
    public func didReceivePartialResult(_ text: String) {
        guard !isSpeaking else { return }
        transcript = text
    }

    public func didReceiveFinalResult(_ text: String) {
        // Ignore anything captured while the assistant is speaking — otherwise the
        // recognizer transcribes our own TTS (e.g. "Reminder created.") and re-triggers
        // the intent. Guards the race where a result is queued before the mic stops.
        guard !isSpeaking else { return }

        transcript = text
        let receivedAt = CFAbsoluteTimeGetCurrent()
        Task(priority: .userInitiated) { [weak self] in
            // Wait for an in-flight engine build (background construction) so a
            // fast first utterance is handled instead of silently dropped.
            await self?.awaitEngineReady()
            guard let nlu = self?.nlu else { return }
            let response = await nlu.handle(text)
            let nluMs = (CFAbsoluteTimeGetCurrent() - receivedAt) * 1000
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.latencyLog.info("NLU handle: \(nluMs, format: .fixed(precision: 1))ms")
                self.apply(response, utterance: text, receivedAt: receivedAt)
            }
        }
    }

    /// Applies an NLU turn result.
    ///
    /// Conversational model (matches Dialogflow): intermediate slot-filling and
    /// confirmation turns only drive the follow-up popup — they do NOT create cards.
    /// A single consolidated card is emitted when the intent is finally fulfilled
    /// (or falls back to GenAI), carrying the full spoken text and extracted slots.
    private func apply(_ response: NLUResponse, utterance: String, receivedAt: CFAbsoluteTime? = nil) {
        conversationTranscripts.append(utterance)

        switch response {
        case .prompt(_, let question, let filled):
            // Still collecting — surface the question, speak it, no card yet.
            pendingQuestion = question
            collectedSlots = filled
            ask(question, receivedAt: receivedAt)

        case .confirm(_, _, let question):
            pendingQuestion = question
            ask(question, receivedAt: receivedAt)

        case .fulfill(let intent, _, let parameters, let message, let confidence, let semanticRescue, let breakdown):
            appendConversationCard(
                intent: .intent(label: intent, confidence: confidence, semanticRescue: semanticRescue),
                slots: parameters.isEmpty ? nil : parameters,
                breakdown: breakdown
            )
            announce(message, receivedAt: receivedAt)

        case .fallback(let url, let confidence, let breakdown):
            appendConversationCard(
                intent: .genai(url: url, confidence: confidence),
                slots: nil,
                breakdown: breakdown
            )

        case .interrupted(let cancelledIntent, let newResult):
            // User switched topics mid slot-filling: show the cancellation notice
            // then apply the new intent's result as if it arrived on a fresh turn.
            pendingQuestion = nil
            collectedSlots = [:]
            appendConversationCard(
                intent: .interrupted(cancelledIntent: cancelledIntent),
                slots: nil
            )
            apply(newResult, utterance: utterance, receivedAt: receivedAt)
        }
    }

    /// Asks a follow-up question. On normal completion, `handleSpeechFinished`
    /// auto-restarts listening to capture the answer.
    private func ask(_ question: String, receivedAt: CFAbsoluteTime? = nil) {
        guard voiceConversationEnabled else { return }
        speakSerialized(question, receivedAt: receivedAt)
    }

    /// Speaks a terminal fulfillment message (e.g. "Reminder created.").
    /// Does NOT auto-listen afterward — the conversation is done.
    private func announce(_ message: String, receivedAt: CFAbsoluteTime? = nil) {
        guard voiceConversationEnabled, !message.isEmpty else { return }
        speakSerialized(message, receivedAt: receivedAt)
    }

    /// Stops the mic engine, waits for the recognizer to drain, then speaks.
    ///
    /// We stop recording with `deactivateSession: false`: the recognizer and the mic
    /// engine are stopped (so the recognizer can't transcribe our own TTS), but the
    /// shared `.playAndRecord` session stays **active** so the synthesizer speaks
    /// immediately on the live session — no deactivate/re-activate round-trip (~100ms
    /// saved). The wait still serialises the handoff so we never start the synthesizer
    /// while the engine is mid-stop. Setting `isSpeaking` synchronously also makes the
    /// `didReceiveFinalResult` guard drop any audio captured during the handoff.
    private func speakSerialized(_ text: String, receivedAt: CFAbsoluteTime? = nil) {
        isSpeaking = true
        if isListening { stopRecording(deactivateSession: false) }
        Task { [weak self] in
            guard let self else { return }
            let teardownStart = CFAbsoluteTimeGetCurrent()
            await self.coordinator.waitForTeardown()
            let teardownMs = (CFAbsoluteTimeGetCurrent() - teardownStart) * 1000
            self.latencyLog.info("waitForTeardown: \(teardownMs, format: .fixed(precision: 1))ms")
            // Re-check: a manual stop / clearResults during teardown may have cancelled
            // the conversation. `speaker.stop()` in clearResults sets isSpeaking = false.
            guard self.isSpeaking else { return }
            await self.speaker.speak(text, locale: self.currentLocale, requestedAt: receivedAt)
        }
    }

    /// Builds one card from the full accumulated conversation and resets the buffer.
    private func appendConversationCard(intent: IntentResult, slots: [String: String]?,
                                        breakdown: ClassificationBreakdown? = nil) {
        let fullText = conversationTranscripts.joined(separator: " ")
        var card = TranscriptionResult(
            text: fullText,
            isFinal: true,
            locale: currentLocale,
            timestamp: Date()
        )
        card.intentResult = intent
        card.slots = slots
        card.classificationBreakdown = breakdown
        results.append(card)

        pendingQuestion = nil
        collectedSlots = [:]
        conversationTranscripts.removeAll()
    }

    public func didEncounterError(_ error: TranscriptionError) {
        self.error = error
        isListening = false
        audioLevel = 0.0
    }

    /// Real measured input power from the capture pipeline (replaces the old
    /// synthetic sine-wave animation). Maps −60…0 dBFS → 0…1 with light smoothing.
    public func didUpdateAudioLevel(_ powerDBFS: Float) {
        guard isListening else { return }
        let clamped = min(max(powerDBFS, -60), 0)
        let normalized = (clamped + 60) / 60
        audioLevel = audioLevel * 0.6 + normalized * 0.4
    }

    public func didChangeState(_ state: TranscriptionState) {
        transcriptionState = state
        audioSource = coordinator.currentRoute.name
        currentLocale = coordinator.currentLocale
    }

    public func didReachEndOfSpeech() {
        // Silence detection ended the session automatically — reset the recording UI
        // (the coordinator has already begun tearing down the live session).
        isListening = false
        audioLevel = 0.0
    }
}
