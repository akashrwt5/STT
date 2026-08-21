// TranscriptionCoordinator.swift
// STT
//
// Public API surface: wires audio session, input provider, and recognition service.

import AVFoundation
import Speech
import os.log

// Lifecycle tracing at `.debug`, which os_log does not emit unless someone turns it
// on — so it costs a host nothing and still answers "did this actually deallocate?".
// It was `print`, which a package has no business doing: it lands in the host app's
// console, unfiltered, with no subsystem to filter it out by.
private let lifecycleLog = Logger(subsystem: "com.voiceintentkit", category: "Lifecycle")


/// The single public entry point for all transcription operations.
///
/// Wires together `AudioSessionManager`, `AudioCaptureService`/`FileCaptureService`,
/// and `SpeechRecognitionService`. The rest of the app only touches this class.
@Observable
@MainActor
final class TranscriptionCoordinator {

    // MARK: - Public State

    private(set) var state: TranscriptionState = .idle
    private(set) var currentTranscript: String = ""
    private(set) var currentRoute: AudioRoute = .builtInMic
    /// Resolved asynchronously on first transcription or explicit locale switch.
    private(set) var currentLocale: Locale

    var isTranscribing: Bool { state.isActive }

    /// Controls automatic silence-based termination for *live* transcription.
    ///
    /// Defaults to `.disabled` (continuous captioning — runs until stopped manually).
    /// Set to `.singleUtterance` for command-style interactions that should end when
    /// the user stops speaking. Has no effect on file transcription.
    var silenceConfiguration: SilenceDetectionConfiguration = .disabled

    /// Content-aware endpointing hook. Given the current stable transcript, assesses
    /// whether it's a finished answer to whatever the conversation is awaiting. The
    /// verdict selects the confirmation window (fast / medium / extended) so a
    /// thinking pause mid-answer doesn't split the turn. `nil` = fixed-window.
    var endpointArbiter: (@MainActor (String) async -> SlotAnswerAssessment)?

    weak var delegate: TranscriptionDelegate?

    // MARK: - AsyncSequence API

    let results: AsyncStream<TranscriptionResult>
    private var resultsContinuation: AsyncStream<TranscriptionResult>.Continuation?

    // MARK: - Available Locales

    /// Returns all locales the on-device recognizer supports.
    ///
    /// `async` because `SpeechTranscriber.supportedLocales` is async in iOS 26.
    var availableLocales: [Locale] {
        get async { await SpeechTranscriber.supportedLocales }
    }

    // MARK: - Dependencies (injected)

    private let sessionManager: AudioSessionManager
    private let recognitionService: SpeechRecognitionService
    // Factory closures are @MainActor because AudioCaptureService/FileCaptureService
    // create AVAudioEngine/AVAudioFile which are @MainActor-isolated in iOS 26.
    private let captureServiceFactory: @MainActor () -> any AudioInputProvider
    private let fileServiceFactory: @MainActor (URL) -> any AudioInputProvider
    /// False when the host owns the microphone + `AVAudioSession` (app-provided audio):
    /// the coordinator then skips session configuration, route management, interruption
    /// handling, and microphone-permission requests.
    private let ownsAudioSession: Bool

    private var activeProvider: (any AudioInputProvider)?
    /// The reusable live-mic provider. Created once and reused across sessions so each
    /// conversation turn restarts the same `AVAudioEngine` instead of allocating a new
    /// one (engine + hardware IO setup costs real time on every turn).
    private var liveProvider: (any AudioInputProvider)?
    /// Set once `resolveCurrentLocaleIfNeeded` has run. Without this guard the resolve
    /// (1–2 async XPC calls into the Speech framework) re-ran on *every* start.
    private var localeResolved = false
    /// Tracks an in-progress live teardown so a restart can wait for it to finish before
    /// starting a new session. Without this, `startLiveTranscription` can be called while
    /// the previous session is still in `.stopping`, hit the guard, and silently no-op —
    /// leaving the mic dead and the transcript frozen.
    private var teardownTask: Task<Void, Never>?
    /// Set during `transcribeFile`; invoked when the recognizer finishes the file so the
    /// result-collection loop can terminate deterministically (instead of polling state).
    private var fileCompletionHandler: (() -> Void)?
    private let logger = Logger(subsystem: "com.voiceintentkit", category: "TranscriptionCoordinator")
    /// TTS-latency teardown breakdown. Filter by subsystem com.voiceintentkit, category
    /// Latency. Logging only — no behaviour change.
    private let latencyLog = Logger(subsystem: "com.voiceintentkit", category: "Latency")

    // MARK: - Init

    /// - Parameters:
    ///   - sessionManager: Manages the `AVAudioSession`.
    ///   - recognitionService: Manages `SpeechAnalyzer` + `SpeechTranscriber`.
    ///   - captureServiceFactory: Returns a fresh `AudioCaptureService` for live mic sessions.
    ///   - fileServiceFactory: Returns a fresh `FileCaptureService` for the given URL.
    ///   - locale: The locale to transcribe in. REQUIRED, and with no default: the
    ///     host chose a language when it built the session, and a coordinator that
    ///     can invent its own locale is a coordinator that can disagree with the
    ///     pack. There is no "resolve it later" path any more.
    init(
        sessionManager: AudioSessionManager,
        recognitionService: SpeechRecognitionService,
        captureServiceFactory: @MainActor @escaping () -> any AudioInputProvider = { AudioCaptureService() },
        fileServiceFactory: @MainActor @escaping (URL) -> any AudioInputProvider = { FileCaptureService(fileURL: $0) },
        locale: Locale,
        ownsAudioSession: Bool = true
    ) {
        let (stream, continuation) = AsyncStream<TranscriptionResult>.makeStream()
        self.results = stream
        self.resultsContinuation = continuation

        self.sessionManager = sessionManager
        self.recognitionService = recognitionService
        self.captureServiceFactory = captureServiceFactory
        self.fileServiceFactory = fileServiceFactory
        self.ownsAudioSession = ownsAudioSession

        self.currentLocale = locale

        sessionManager.delegate = self
        recognitionService.delegate = self
    }

    /// Convenience initializer with no external dependencies.
    convenience init(locale: Locale) {
        self.init(
            sessionManager: AudioSessionManager(),
            recognitionService: SpeechRecognitionService(locale: locale),
            locale: locale
        )
    }

    /// Convenience initializer for host-owned audio. The given `AppAudioInputProvider`
    /// is fed by the app via `provideAudio`; the coordinator does not open the mic or
    /// touch the `AVAudioSession` (`ownsAudioSession: false`).
    convenience init(appAudioProvider: AppAudioInputProvider, locale: Locale) {
        self.init(
            sessionManager: AudioSessionManager(),
            recognitionService: SpeechRecognitionService(locale: locale),
            captureServiceFactory: { appAudioProvider },
            locale: locale,
            ownsAudioSession: false
        )
    }

    deinit {
        lifecycleLog.debug("[Deinit] TranscriptionCoordinator")
    }

    // MARK: - Pre-warm

    /// Pre-loads the Apple speech model (locale resolve → install/reserve →
    /// SpeechTranscriber + SpeechAnalyzer creation) in the background so the first
    /// mic tap is instant. Returns immediately. Call from the view's `.onAppear`.
    func prewarm() {
        recognitionService.prewarm()
    }

    /// Awaitable Load — kicks off prewarm and returns when it's done. Used by
    /// the diagnostic Load button so the MemoryProbe brackets a finished cycle.
    func loadNow() async {
        await recognitionService.awaitPrewarm()
    }

    /// Releases every speech-related ref held by the recognition service.
    /// Diagnostic — used by the Unload button to measure whether the speech
    /// framework returns its dirty memory when we drop our handles.
    func unload() async {
        await recognitionService.unload()
    }

    // MARK: - IntentClassifier Lifecycle (Diagnostic) — REMOVED
    //
    // `initIntentClassifier()` / `freeIntentClassifier()` built an English
    // classifier through the deleted `LanguagePackRegistry`, for a memory-
    // diagnostic view.
    // Nothing in the package called them, and the pair carried two properties
    // this refactor is removing: a hardcoded `"en"`, and a second construction
    // path for the classifier that could drift from the real one while claiming
    // in its own doc comment to stay "in lock-step with production loading".
    //
    // A diagnostic that builds the object differently from production measures
    // the diagnostic. If the memory question comes back, hold a
    // `PackIntentClassifier` built by the same `PackEngineFactory` path the
    // session uses.
    //
    // `loadStage3()` / `releaseStage3()` went with them. They acted on that
    // second classifier instance, so they could only ever have moved memory the
    // production path did not hold. Stage 3 is owned by the engine — the session
    // reaches it through `ConversationEngine.loadStage3()`, which is pack-gated:
    // a pack that disables the semantic stage refuses the request instead of
    // honouring it, because the pack's accuracy numbers were measured with it
    // off. A transcription coordinator has no business in that decision.

    // MARK: - Permission Check

    /// Checks both microphone and speech recognition permissions without requesting them.
    func checkPermissions() async -> PermissionStatus {
        let micGranted = AVAudioApplication.shared.recordPermission == .granted
        let speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        switch (micGranted, speechGranted) {
        case (true, true):   return .granted
        case (false, true):  return .microphoneDenied
        case (true, false):  return .speechRecognitionDenied
        case (false, false): return .allDenied
        }
    }

    // MARK: - Live Transcription

    /// Starts real-time transcription from the device microphone (or hearing aid).
    ///
    /// - Throws: `TranscriptionError.microphonePermissionDenied` if mic access is not granted.
    /// - Throws: `TranscriptionError.speechRecognitionPermissionDenied` if STT access is denied.
    /// - Throws: `TranscriptionError.audioSessionSetupFailed` if the audio session cannot start.
    /// - Throws: `TranscriptionError.analyzerFailed` if the speech engine cannot start.
    func startLiveTranscription() async throws {
        // Phase timing (logging only): the hang detector caught a one-time ~2.5s
        // main-thread stall inside the FIRST mic start — these marks attribute it
        // to a specific phase (permissions / locale / session / engine / analyzer).
        var phaseStart = CFAbsoluteTimeGetCurrent()
        func phase(_ name: StaticString) {
            let now = CFAbsoluteTimeGetCurrent()
            latencyLog.info("micStart phase \(name, privacy: .public): \((now - phaseStart) * 1000, format: .fixed(precision: 0))ms")
            phaseStart = now
        }

        // Wait for any in-progress teardown to finish so we always start from a clean
        // `.idle` state (and a released audio session/engine), not on top of a session
        // that is still tearing down. Fixes the freeze where a restart no-ops because
        // the previous session was still `.stopping`.
        await teardownTask?.value
        teardownTask = nil
        phase("awaitTeardown")

        guard !state.isActive, state != .stopping else { return }

        transition(to: .requestingPermissions)
        // App-owned audio: host handles mic permission; we still need speech-recognition auth.
        try await requestPermissionsOrThrow(requiresMicrophone: ownsAudioSession)
        phase("permissions")

        // Resolve the locale asynchronously now that we're in an async context.
        await resolveCurrentLocaleIfNeeded()
        phase("resolveLocale")
        transition(to: .preparingAudio)

        // App-owned audio: the host owns the AVAudioSession (category, activation, route,
        // interruptions), so the coordinator must not configure or inspect it.
        if ownsAudioSession {
            try await sessionManager.configure()
            currentRoute = sessionManager.currentRoute
        }
        phase("sessionConfigure")
        currentTranscript = ""

        let provider = liveProvider ?? captureServiceFactory()
        liveProvider = provider
        activeProvider = provider
        phase("providerCreate")

        // .progressiveTranscription yields partial results immediately — ideal for live mic.
        try await recognitionService.startTranscribing(
            from: provider,
            preset: .progressiveTranscription,
            silenceConfiguration: silenceConfiguration,
            endpointArbiter: endpointArbiter
        )
        phase("startTranscribing")
        transition(to: .transcribing)
        logger.info("Live transcription started. Silence detection: \(self.silenceConfiguration.isEnabled ? "on" : "off").")
    }

    /// Stops live transcription and releases audio resources.
    ///
    /// Permits stopping from any pre-active state too (e.g. while permissions are being
    /// requested or audio is still being prepared on first launch), so a stop tap is
    /// never silently ignored.
    ///
    /// - Parameter deactivateSession: when `true` (default) the shared `AVAudioSession`
    ///   is deactivated as part of teardown. The TTS handoff passes `false`: it stops
    ///   the recognizer and the mic engine (so the recognizer can't transcribe our own
    ///   voice) but leaves the session **active**, so the synthesizer can speak
    ///   immediately on the live session instead of waiting ~100ms for a
    ///   deactivate/re-activate round-trip. Both paths use the same `.playAndRecord`
    ///   category, so no reconfiguration is needed between them.
    func stopLiveTranscription(deactivateSession: Bool = true) {
        guard state != .idle, state != .stopping else { return }
        transition(to: .stopping)
        teardownTask = Task {
            // Latency instrumentation (logging only): split the teardown so we can see
            // whether SpeechAnalyzer drain or AVAudioSession teardown dominates.
            let t0 = CFAbsoluteTimeGetCurrent()
            await recognitionService.stopTranscribing()
            let stopMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            activeProvider?.stop()
            activeProvider = nil
            let t1 = CFAbsoluteTimeGetCurrent()
            if deactivateSession && ownsAudioSession {
                sessionManager.tearDown()
            }
            let tearMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
            transition(to: .idle)
            latencyLog.info("teardown: stopTranscribing=\(stopMs, format: .fixed(precision: 1))ms sessionTearDown=\(tearMs, format: .fixed(precision: 1))ms deactivated=\(deactivateSession)")
            logger.info("Live transcription stopped (deactivateSession: \(deactivateSession)).")
        }
    }

    /// Suspends until any in-progress live teardown has completed. Callers that need the
    /// audio session fully released before doing their own audio work (e.g. speaking a
    /// TTS prompt) should await this first.
    func waitForTeardown() async {
        await teardownTask?.value
    }

    /// Deactivates the shared audio session if no session is running. The conversation
    /// flow deliberately keeps the session active across recognizer↔TTS handoffs (see
    /// `recognitionServiceDidDetectSilence`); the owning screen calls this on dismiss
    /// so the session doesn't outlive the conversation.
    func releaseAudioSession() {
        guard ownsAudioSession, state == .idle else { return }
        sessionManager.tearDown()
    }

    // MARK: - File Transcription

    /// Transcribes an audio file and returns the full transcript when complete.
    ///
    /// - Parameters:
    ///   - url: Path to the audio file (m4a, wav, mp3, caf).
    ///   - onProgress: Called on the main actor with real frame-based progress (0...1).
    /// - Returns: The complete transcribed text.
    /// - Throws: `TranscriptionError.fileNotFound` if the URL is inaccessible.
    func transcribeFile(
        at url: URL,
        onProgress: @MainActor @escaping (Double) -> Void = { _ in }
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.fileNotFound(url)
        }

        // The recognition service holds one analyzer/transcriber and one results
        // continuation — a file job starting while a live session is active would
        // corrupt both. Reject instead of silently interleaving.
        guard !state.isActive, state != .stopping else {
            throw TranscriptionError.sessionAlreadyActive
        }
        await teardownTask?.value
        teardownTask = nil

        transition(to: .requestingPermissions)
        // File transcription does not use the microphone — only speech recognition auth.
        try await requestPermissionsOrThrow(requiresMicrophone: false)
        await resolveCurrentLocaleIfNeeded()
        transition(to: .processingFile(progress: 0.0))

        currentTranscript = ""
        var fullTranscript = ""

        let provider = fileServiceFactory(url)
        activeProvider = provider

        let (fileStream, fileContinuation) = AsyncStream<TranscriptionResult>.makeStream()
        let previousContinuation = resultsContinuation
        resultsContinuation = fileContinuation
        // The recognizer signals completion via `recognitionServiceDidComplete`, which
        // finishes the stream so the loop below terminates deterministically — no polling.
        fileCompletionHandler = { fileContinuation.finish() }

        // Drive UI progress from the file reader's real frame position (authoritative),
        // rather than guessing from transcript length.
        var progressTask: Task<Void, Never>?
        if let progressStream = provider.progressStream {
            progressTask = Task { [weak self] in
                for await fraction in progressStream {
                    let clamped = max(0.05, min(0.99, fraction))
                    onProgress(clamped)
                    if let self, case .processingFile = self.state {
                        self.state = .processingFile(progress: clamped)
                    }
                }
            }
        }

        defer {
            progressTask?.cancel()
            fileCompletionHandler = nil
            resultsContinuation = previousContinuation
            activeProvider = nil
        }

        // .transcription optimises for accuracy over the complete audio buffer — ideal for files.
        try await recognitionService.startTranscribing(from: provider, preset: .transcription)

        for await result in fileStream {
            guard !Task.isCancelled else { break }
            if result.isFinal {
                fullTranscript += (fullTranscript.isEmpty ? "" : " ") + result.text
            }
        }

        provider.stop()
        await recognitionService.stopTranscribing()
        transition(to: .idle)
        logger.info("File transcription complete. Characters: \(fullTranscript.count)")
        return fullTranscript
    }

    /// Cancels an in-progress file transcription and releases resources.
    func cancelFileTranscription() {
        guard case .processingFile = state else { return }
        fileCompletionHandler?()
        activeProvider?.stop()
        Task {
            await recognitionService.stopTranscribing()
            transition(to: .idle)
            logger.info("File transcription cancelled.")
        }
    }

    // MARK: - Locale Switching

    /// Switches the active transcription locale for this coordinator.
    ///
    /// Persists nothing. It used to write the identifier into the HOST app's
    /// `UserDefaults.standard` under `stt.userSelectedLocale`, with a rollback on
    /// failure, because the recognition service's prewarm read the locale back out
    /// of that same key. Both halves are gone: the service prewarms for the locale
    /// it already holds, so there is nothing to hand across through global state.
    ///
    /// That persistence came from the app this code was copied out of, where a
    /// user-facing language picker legitimately wanted the choice to survive a
    /// relaunch. In a package it is the SDK writing an un-namespaced key into a
    /// host's shared defaults, and — on the failure path — a stale value quietly
    /// becoming the locale the recogniser ran in. Remembering a user's choice is
    /// the host's job; it passes the result in as configuration.
    ///
    /// - Parameter identifier: BCP-47 locale string (e.g. "hi-IN", "en-US").
    /// - Throws: `TranscriptionError.localeNotSupported` if no model exists for this locale.
    func switchLocale(to identifier: String) async throws {
        try await recognitionService.switchLocale(to: identifier)
        // `supportedLocale(equivalentTo:)` is async in iOS 26.
        if let matched = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
            currentLocale = matched
        }
        localeResolved = true
        logger.info("Locale changed to: \(identifier)")
    }

    // MARK: - Private Helpers

    private func transition(to newState: TranscriptionState) {
        state = newState
        delegate?.didChangeState(newState)
    }

    /// Canonicalises `currentLocale` against the Speech framework's supported set —
    /// "en-US" as the host spelled it becomes whatever `SpeechTranscriber` calls it.
    /// Only runs once per coordinator, enforced by `localeResolved` (previously this
    /// comment claimed "once" but the resolve re-ran, with its XPC calls, on every start).
    ///
    /// It used to run the full auto-detect chain from the persisted override —
    /// override → device locale → device language → en-IN. Two things were wrong with
    /// that: the value came from global state rather than from the caller, and the
    /// chain's later steps substitute a DIFFERENT LANGUAGE, which is the one thing
    /// this package refuses to do anywhere else. An unsupported locale is now left
    /// alone so `startTranscribing` throws `localeNotSupported` for it, instead of
    /// transcribing English for a session bound to a Danish pack.
    private func resolveCurrentLocaleIfNeeded() async {
        guard !localeResolved else { return }
        if let matched = await SpeechTranscriber.supportedLocale(equivalentTo: currentLocale) {
            currentLocale = matched
        }
        localeResolved = true
    }

    private func requestPermissionsOrThrow(requiresMicrophone: Bool = true) async throws {
        // Fast path: skip the async request round-trips when already authorized —
        // this runs on every conversation turn.
        if requiresMicrophone, AVAudioApplication.shared.recordPermission != .granted {
            let micGranted = await AVAudioApplication.requestRecordPermission()
            guard micGranted else { throw TranscriptionError.microphonePermissionDenied }
        }

        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            let speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard speechStatus == .authorized else {
                throw TranscriptionError.speechRecognitionPermissionDenied
            }
        }
    }
}

// MARK: - AudioSessionManagerDelegate

extension TranscriptionCoordinator: AudioSessionManagerDelegate {
    func audioSessionManager(_ manager: AudioSessionManager, routeDidChangeTo route: AudioRoute) {
        currentRoute = route
    }

    func audioSessionManagerWasInterrupted(_ manager: AudioSessionManager) {
        if state == .transcribing { stopLiveTranscription() }
    }

    func audioSessionManagerInterruptionEnded(_ manager: AudioSessionManager, shouldResume: Bool) {
        guard shouldResume else { return }
        // Surface resume failures instead of swallowing them with `try?` — a failed
        // resume previously left the mic silently dead with no signal to the UI.
        Task {
            do {
                try await startLiveTranscription()
            } catch let error as TranscriptionError {
                delegate?.didEncounterError(error)
            } catch {
                delegate?.didEncounterError(.analyzerFailed(error))
            }
        }
    }
}

// MARK: - SpeechRecognitionServiceDelegate

extension TranscriptionCoordinator: SpeechRecognitionServiceDelegate {
    func recognitionService(_ service: SpeechRecognitionService, didReceivePartialResult result: TranscriptionResult) {
        currentTranscript = result.text
        logger.info("[Coordinator] Partial → forwarding to delegate (nil? \(self.delegate == nil)): '\(result.text)'")
        delegate?.didReceivePartialResult(result.text)
        resultsContinuation?.yield(result)
    }

    func recognitionService(_ service: SpeechRecognitionService, didReceiveFinalResult result: TranscriptionResult) {
        currentTranscript = result.text
        logger.info("[Coordinator] Final → forwarding to delegate (nil? \(self.delegate == nil)): '\(result.text)'")
        delegate?.didReceiveFinalResult(result.text)
        resultsContinuation?.yield(result)
    }

    func recognitionService(_ service: SpeechRecognitionService, didFailWith error: TranscriptionError) {
        transition(to: .failed(error))
        delegate?.didEncounterError(error)
        activeProvider?.stop()
        activeProvider = nil
        sessionManager.tearDown()
    }

    func recognitionServiceDidComplete(_ service: SpeechRecognitionService) {
        // Used by file transcription to end its result-collection loop deterministically.
        fileCompletionHandler?()
    }

    func recognitionService(_ service: SpeechRecognitionService, didUpdateAudioLevel powerDBFS: Float) {
        delegate?.didUpdateAudioLevel(powerDBFS)
    }

    func recognitionServiceDidDetectSilence(_ service: SpeechRecognitionService) {
        // Only relevant for live transcription. Stop the recognizer and mic but keep
        // the audio session ACTIVE: in a conversation the very next step is a TTS
        // prompt, and speaking onto a just-deactivated session is both slower
        // (deactivate/re-activate round-trip) and the known trigger for
        // AVSpeechSynthesizer silently dropping utterances. The session is released
        // by `releaseAudioSession()` when the owning screen goes away.
        logger.info("[Coordinator] Silence detected — stopping live transcription.")
        guard state == .transcribing else { return }
        delegate?.didReachEndOfSpeech()
        stopLiveTranscription(deactivateSession: false)
    }
}
