// TranscriptionCoordinator.swift
// STT
//
// Public API surface: wires audio session, input provider, and recognition service.

import AVFoundation
import Speech
import os.log

private let localeDefaultsKey = "stt.userSelectedLocale"

/// The single public entry point for all transcription operations.
///
/// Wires together `AudioSessionManager`, `AudioCaptureService`/`FileCaptureService`,
/// and `SpeechRecognitionService`. The rest of the app only touches this class.
@Observable
@MainActor
public final class TranscriptionCoordinator {

    // MARK: - Public State

    public private(set) var state: TranscriptionState = .idle
    public private(set) var currentTranscript: String = ""
    public private(set) var currentRoute: AudioRoute = .builtInMic
    /// Resolved asynchronously on first transcription or explicit locale switch.
    public private(set) var currentLocale: Locale

    public var isTranscribing: Bool { state.isActive }

    /// Controls automatic silence-based termination for *live* transcription.
    ///
    /// Defaults to `.disabled` (continuous captioning — runs until stopped manually).
    /// Set to `.singleUtterance` for command-style interactions that should end when
    /// the user stops speaking. Has no effect on file transcription.
    public var silenceConfiguration: SilenceDetectionConfiguration = .disabled

    public weak var delegate: TranscriptionDelegate?

    // MARK: - AsyncSequence API

    public let results: AsyncStream<TranscriptionResult>
    private var resultsContinuation: AsyncStream<TranscriptionResult>.Continuation?

    // MARK: - Available Locales

    /// Returns all locales the on-device recognizer supports.
    ///
    /// `async` because `SpeechTranscriber.supportedLocales` is async in iOS 26.
    public var availableLocales: [Locale] {
        get async { await SpeechTranscriber.supportedLocales }
    }

    // MARK: - Dependencies (injected)

    private let sessionManager: AudioSessionManager
    private let recognitionService: SpeechRecognitionService
    // Factory closures are @MainActor because AudioCaptureService/FileCaptureService
    // create AVAudioEngine/AVAudioFile which are @MainActor-isolated in iOS 26.
    private let captureServiceFactory: @MainActor () -> any AudioInputProvider
    private let fileServiceFactory: @MainActor (URL) -> any AudioInputProvider

    private var activeProvider: (any AudioInputProvider)?
    /// Tracks an in-progress live teardown so a restart can wait for it to finish before
    /// starting a new session. Without this, `startLiveTranscription` can be called while
    /// the previous session is still in `.stopping`, hit the guard, and silently no-op —
    /// leaving the mic dead and the transcript frozen.
    private var teardownTask: Task<Void, Never>?
    /// Set during `transcribeFile`; invoked when the recognizer finishes the file so the
    /// result-collection loop can terminate deterministically (instead of polling state).
    private var fileCompletionHandler: (() -> Void)?
    private let logger = Logger(subsystem: "com.stt.module", category: "TranscriptionCoordinator")
    /// TTS-latency teardown breakdown. Filter by subsystem com.stt.module, category
    /// Latency. Logging only — no behaviour change.
    private let latencyLog = Logger(subsystem: "com.stt.module", category: "Latency")

    // MARK: - Init

    /// - Parameters:
    ///   - sessionManager: Manages the `AVAudioSession`.
    ///   - recognitionService: Manages `SpeechAnalyzer` + `SpeechTranscriber`.
    ///   - captureServiceFactory: Returns a fresh `AudioCaptureService` for live mic sessions.
    ///   - fileServiceFactory: Returns a fresh `FileCaptureService` for the given URL.
    ///   - locale: Initial locale. Defaults to en-IN; resolved asynchronously on first use.
    public init(
        sessionManager: AudioSessionManager,
        recognitionService: SpeechRecognitionService,
        captureServiceFactory: @MainActor @escaping () -> any AudioInputProvider = { AudioCaptureService() },
        fileServiceFactory: @MainActor @escaping (URL) -> any AudioInputProvider = { FileCaptureService(fileURL: $0) },
        locale: Locale? = nil
    ) {
        let (stream, continuation) = AsyncStream<TranscriptionResult>.makeStream()
        self.results = stream
        self.resultsContinuation = continuation

        self.sessionManager = sessionManager
        self.recognitionService = recognitionService
        self.captureServiceFactory = captureServiceFactory
        self.fileServiceFactory = fileServiceFactory

        // Default to en-IN; will be resolved asynchronously in startLiveTranscription/transcribeFile
        // if no explicit locale is provided.
        let savedOverride = UserDefaults.standard.string(forKey: localeDefaultsKey)
        self.currentLocale = locale ?? Locale(identifier: savedOverride ?? "en-IN")

        sessionManager.delegate = self
        recognitionService.delegate = self
    }

    /// Convenience initializer with no external dependencies.
    public convenience init() {
        let savedOverride = UserDefaults.standard.string(forKey: localeDefaultsKey)
        let defaultLocale = Locale(identifier: savedOverride ?? "en-IN")
        let recognitionService = SpeechRecognitionService(locale: defaultLocale)
        self.init(
            sessionManager: AudioSessionManager(),
            recognitionService: recognitionService,
            locale: defaultLocale
        )
    }

    // MARK: - Pre-warm

    /// Pre-loads the Apple speech model (locale resolve → install/reserve →
    /// SpeechTranscriber + SpeechAnalyzer creation) in the background so the first
    /// mic tap is instant. Returns immediately. Call from the view's `.onAppear`.
    public func prewarm() {
        recognitionService.prewarm()
    }

    /// Awaitable Load — kicks off prewarm and returns when it's done. Used by
    /// the diagnostic Load button so the MemoryProbe brackets a finished cycle.
    public func loadNow() async {
        await recognitionService.awaitPrewarm()
    }

    /// Releases every speech-related ref held by the recognition service.
    /// Diagnostic — used by the Unload button to measure whether the speech
    /// framework returns its dirty memory when we drop our handles.
    public func unload() async {
        await recognitionService.unload()
    }

    // MARK: - IntentClassifier Lifecycle (Diagnostic)

    /// The IntentClassifier instance — when nil, no NLU is available. Owned
    /// here so dropping our reference is the *only* thing keeping it alive,
    /// which lets `freeIntentClassifier()` truly deinit the service.
    public private(set) var intentClassifier: IntentClassifierService?

    /// Diagnostic — create the IntentClassifier instance. Idempotent.
    public func initIntentClassifier() {
        if intentClassifier == nil {
            intentClassifier = IntentClassifierService()
        }
    }

    /// Diagnostic — drop our reference to the IntentClassifier. If nothing
    /// else holds it, the actor deinits (watch console for `[Deinit]`).
    public func freeIntentClassifier() {
        intentClassifier = nil
    }

    /// Diagnostic — manually load Stage 3 (MiniLM + SemanticHead) on the
    /// current IntentClassifier instance. No-op if IC not initialized.
    public func loadStage3() async {
        await intentClassifier?.loadStage3()
    }

    /// Diagnostic — release Stage 3 refs on the current IntentClassifier.
    public func releaseStage3() async {
        await intentClassifier?.releaseStage3()
    }

    // MARK: - Permission Check

    /// Checks both microphone and speech recognition permissions without requesting them.
    public func checkPermissions() async -> PermissionStatus {
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
    public func startLiveTranscription() async throws {
        // Wait for any in-progress teardown to finish so we always start from a clean
        // `.idle` state (and a released audio session/engine), not on top of a session
        // that is still tearing down. Fixes the freeze where a restart no-ops because
        // the previous session was still `.stopping`.
        await teardownTask?.value
        teardownTask = nil

        guard !state.isActive, state != .stopping else { return }

        transition(to: .requestingPermissions)
        try await requestPermissionsOrThrow()

        // Resolve the locale asynchronously now that we're in an async context.
        await resolveCurrentLocaleIfNeeded()
        transition(to: .preparingAudio)

        try await sessionManager.configure()
        currentRoute = sessionManager.currentRoute
        currentTranscript = ""

        let provider = captureServiceFactory()
        activeProvider = provider

        // .progressiveTranscription yields partial results immediately — ideal for live mic.
        try await recognitionService.startTranscribing(
            from: provider,
            preset: .progressiveTranscription,
            silenceConfiguration: silenceConfiguration
        )
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
    public func stopLiveTranscription(deactivateSession: Bool = true) {
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
            if deactivateSession {
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
    public func waitForTeardown() async {
        await teardownTask?.value
    }

    // MARK: - File Transcription

    /// Transcribes an audio file and returns the full transcript when complete.
    ///
    /// - Parameters:
    ///   - url: Path to the audio file (m4a, wav, mp3, caf).
    ///   - onProgress: Called on the main actor with real frame-based progress (0...1).
    /// - Returns: The complete transcribed text.
    /// - Throws: `TranscriptionError.fileNotFound` if the URL is inaccessible.
    public func transcribeFile(
        at url: URL,
        onProgress: @MainActor @escaping (Double) -> Void = { _ in }
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.fileNotFound(url)
        }

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
    public func cancelFileTranscription() {
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

    /// Switches the active transcription locale and persists it to `UserDefaults`.
    ///
    /// - Parameter identifier: BCP-47 locale string (e.g. "hi-IN", "en-US").
    /// - Throws: `TranscriptionError.localeNotSupported` if no model exists for this locale.
    public func switchLocale(to identifier: String) async throws {
        try await recognitionService.switchLocale(to: identifier)
        // `supportedLocale(equivalentTo:)` is async in iOS 26.
        if let matched = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
            currentLocale = matched
        }
        UserDefaults.standard.set(identifier, forKey: localeDefaultsKey)
        logger.info("Locale changed to: \(identifier)")
    }

    // MARK: - Private Helpers

    private func transition(to newState: TranscriptionState) {
        state = newState
        delegate?.didChangeState(newState)
    }

    /// Resolves `currentLocale` from the async SpeechTranscriber API if it hasn't been
    /// set by an explicit `switchLocale` call. Only resolves once per session.
    private func resolveCurrentLocaleIfNeeded() async {
        let savedOverride = UserDefaults.standard.string(forKey: localeDefaultsKey)
        let resolved = await SpeechRecognitionService.resolveLocale(userOverride: savedOverride)
        currentLocale = resolved
    }

    private func requestPermissionsOrThrow(requiresMicrophone: Bool = true) async throws {
        if requiresMicrophone {
            let micGranted = await AVAudioApplication.requestRecordPermission()
            guard micGranted else { throw TranscriptionError.microphonePermissionDenied }
        }

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

// MARK: - AudioSessionManagerDelegate

extension TranscriptionCoordinator: AudioSessionManagerDelegate {
    public func audioSessionManager(_ manager: AudioSessionManager, routeDidChangeTo route: AudioRoute) {
        currentRoute = route
    }

    public func audioSessionManagerWasInterrupted(_ manager: AudioSessionManager) {
        if state == .transcribing { stopLiveTranscription() }
    }

    public func audioSessionManagerInterruptionEnded(_ manager: AudioSessionManager, shouldResume: Bool) {
        if shouldResume { Task { try? await startLiveTranscription() } }
    }
}

// MARK: - SpeechRecognitionServiceDelegate

extension TranscriptionCoordinator: SpeechRecognitionServiceDelegate {
    public func recognitionService(_ service: SpeechRecognitionService, didReceivePartialResult result: TranscriptionResult) {
        currentTranscript = result.text
        logger.info("[Coordinator] Partial → forwarding to delegate (nil? \(self.delegate == nil)): '\(result.text)'")
        delegate?.didReceivePartialResult(result.text)
        resultsContinuation?.yield(result)
    }

    public func recognitionService(_ service: SpeechRecognitionService, didReceiveFinalResult result: TranscriptionResult) {
        currentTranscript = result.text
        logger.info("[Coordinator] Final → forwarding to delegate (nil? \(self.delegate == nil)): '\(result.text)'")
        delegate?.didReceiveFinalResult(result.text)
        resultsContinuation?.yield(result)
    }

    public func recognitionService(_ service: SpeechRecognitionService, didFailWith error: TranscriptionError) {
        transition(to: .failed(error))
        delegate?.didEncounterError(error)
        activeProvider?.stop()
        activeProvider = nil
        sessionManager.tearDown()
    }

    public func recognitionServiceDidComplete(_ service: SpeechRecognitionService) {
        // Used by file transcription to end its result-collection loop deterministically.
        fileCompletionHandler?()
    }

    public func recognitionServiceDidDetectSilence(_ service: SpeechRecognitionService) {
        // Only relevant for live transcription. Tear down the session the same way a
        // manual stop would, so the UI returns to idle and resources are released.
        logger.info("[Coordinator] Silence detected — stopping live transcription.")
        guard state == .transcribing else { return }
        delegate?.didReachEndOfSpeech()
        stopLiveTranscription()
    }
}
