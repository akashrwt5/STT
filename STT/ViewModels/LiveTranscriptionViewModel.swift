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
    private let classifier = IntentClassifierService.shared
    private let nlu = NLUEngine()
    private let speaker = ConversationSpeaker()
    /// Accumulates the spoken text across a multi-turn exchange so the final card
    /// shows the complete phrase (e.g. "remind me" + "take medication" + "tomorrow").
    private var conversationTranscripts: [String] = []
    private var levelTimer: Timer?
    private var animPhase: Double = 0
    private let logger = Logger(subsystem: "com.stt.module", category: "LiveTranscriptionViewModel")

    // MARK: - Init

    public init(coordinator: TranscriptionCoordinator) {
        self.coordinator = coordinator
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
        if isListening { stopRecording() } else { startRecording() }
    }

    /// Switches the active transcription locale and restarts the session if needed.
    public func switchLocale(_ identifier: String) {
        Task {
            do {
                if isListening { stopRecording() }
                try await coordinator.switchLocale(to: identifier)
                currentLocale = coordinator.currentLocale
            } catch {
                self.error = error as? TranscriptionError
            }
        }
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
        nlu.reset()
    }

    // MARK: - Private

    private func startRecording() {
        error = nil
        Task {
            do {
                try await coordinator.startLiveTranscription()
                isListening = true
                startAudioLevelAnimation()
            } catch let err as TranscriptionError {
                self.error = err
                isListening = false
            } catch {
                self.error = .analyzerFailed(error)
                isListening = false
            }
        }
    }

    private func stopRecording() {
        coordinator.stopLiveTranscription()
        isListening = false
        stopAudioLevelAnimation()
    }

    // MARK: - Audio Level Animation

    private func startAudioLevelAnimation() {
        animPhase = 0
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.animPhase += 0.12
                self.audioLevel = Float(abs(sin(self.animPhase)) * 0.65 + 0.2)
            }
        }
    }

    private func stopAudioLevelAnimation() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0.0
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
        // Route the utterance through the multi-turn NLU engine. Inference runs off the
        // main thread; the engine drives the conversation serially (one turn at a time).
        Task.detached(priority: .userInitiated) { [nlu, weak self] in
            let response = nlu.handle(text)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apply(response, utterance: text)
            }
        }
    }

    /// Applies an NLU turn result.
    ///
    /// Conversational model (matches Dialogflow): intermediate slot-filling and
    /// confirmation turns only drive the follow-up popup — they do NOT create cards.
    /// A single consolidated card is emitted when the intent is finally fulfilled
    /// (or falls back to GenAI), carrying the full spoken text and extracted slots.
    private func apply(_ response: NLUResponse, utterance: String) {
        conversationTranscripts.append(utterance)

        switch response {
        case .prompt(_, let question, let filled):
            // Still collecting — surface the question, speak it, no card yet.
            pendingQuestion = question
            collectedSlots = filled
            ask(question)

        case .confirm(_, _, let question):
            pendingQuestion = question
            ask(question)

        case .fulfill(let intent, _, let parameters, let message, let confidence):
            appendConversationCard(
                intent: .intent(label: intent, confidence: confidence),
                slots: parameters.isEmpty ? nil : parameters
            )
            announce(message)

        case .fallback(let url, let confidence):
            appendConversationCard(
                intent: .genai(url: url, confidence: confidence),
                slots: nil
            )
        }
    }

    /// Asks a follow-up question. On normal completion, `handleSpeechFinished`
    /// auto-restarts listening to capture the answer.
    private func ask(_ question: String) {
        guard voiceConversationEnabled else { return }
        speakSerialized(question)
    }

    /// Speaks a terminal fulfillment message (e.g. "Reminder created.").
    /// Does NOT auto-listen afterward — the conversation is done.
    private func announce(_ message: String) {
        guard voiceConversationEnabled, !message.isEmpty else { return }
        speakSerialized(message)
    }

    /// Stops the mic, waits for the audio session/engine to fully tear down, then speaks.
    ///
    /// The wait is essential: without it the TTS playback session and the recording
    /// session race over the shared `AVAudioSession`, leaving the engine started on a
    /// dirty session (no buffers → frozen transcript) on the subsequent restart. Setting
    /// `isSpeaking` synchronously also makes the `didReceiveFinalResult` guard drop any
    /// audio captured during the handoff (no self-transcription).
    private func speakSerialized(_ text: String) {
        isSpeaking = true
        if isListening { stopRecording() }
        Task { [weak self] in
            guard let self else { return }
            await self.coordinator.waitForTeardown()
            // Re-check: a manual stop / clearResults during teardown may have cancelled
            // the conversation. `speaker.stop()` in clearResults sets isSpeaking = false.
            guard self.isSpeaking else { return }
            self.speaker.speak(text, locale: self.currentLocale)
        }
    }

    /// Builds one card from the full accumulated conversation and resets the buffer.
    private func appendConversationCard(intent: IntentResult, slots: [String: String]?) {
        let fullText = conversationTranscripts.joined(separator: " ")
        var card = TranscriptionResult(
            text: fullText,
            isFinal: true,
            locale: currentLocale,
            timestamp: Date()
        )
        card.intentResult = intent
        card.slots = slots
        results.append(card)

        pendingQuestion = nil
        collectedSlots = [:]
        conversationTranscripts.removeAll()
    }

    public func didEncounterError(_ error: TranscriptionError) {
        self.error = error
        isListening = false
        stopAudioLevelAnimation()
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
        stopAudioLevelAnimation()
    }
}
