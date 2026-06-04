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
    private let logger = Logger(subsystem: "com.stt.module", category: "TranscriptionCoordinator")

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
        guard !state.isActive, state != .stopping else { return }

        transition(to: .requestingPermissions)
        try await requestPermissionsOrThrow()

        // Resolve the locale asynchronously now that we're in an async context.
        await resolveCurrentLocaleIfNeeded()
        transition(to: .preparingAudio)

        try sessionManager.configure()
        currentRoute = sessionManager.currentRoute
        currentTranscript = ""

        let provider = captureServiceFactory()
        activeProvider = provider

        // .progressiveTranscription yields partial results immediately — ideal for live mic.
        try await recognitionService.startTranscribing(from: provider, preset: .progressiveTranscription)
        transition(to: .transcribing)
        logger.info("Live transcription started.")
    }

    /// Stops live transcription and releases audio resources.
    public func stopLiveTranscription() {
        guard state == .transcribing else { return }
        transition(to: .stopping)
        Task {
            await recognitionService.stopTranscribing()
            activeProvider?.stop()
            activeProvider = nil
            sessionManager.tearDown()
            transition(to: .idle)
            logger.info("Live transcription stopped.")
        }
    }

    // MARK: - File Transcription

    /// Transcribes an audio file and returns the full transcript when complete.
    ///
    /// - Parameter url: Path to the audio file (m4a, wav, mp3, caf).
    /// - Returns: The complete transcribed text.
    /// - Throws: `TranscriptionError.fileNotFound` if the URL is inaccessible.
    public func transcribeFile(at url: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.fileNotFound(url)
        }

        transition(to: .requestingPermissions)
        try await requestPermissionsOrThrow()
        await resolveCurrentLocaleIfNeeded()
        transition(to: .processingFile(progress: 0.0))

        currentTranscript = ""
        var fullTranscript = ""

        let provider = fileServiceFactory(url)
        activeProvider = provider

        let (fileStream, fileContinuation) = AsyncStream<TranscriptionResult>.makeStream()
        let previousContinuation = resultsContinuation
        resultsContinuation = fileContinuation

        // .transcription optimises for accuracy over the complete audio buffer — ideal for files.
        try await recognitionService.startTranscribing(from: provider, preset: .transcription)
        transition(to: .processingFile(progress: 0.1))

        for await result in fileStream {
            if result.isFinal {
                fullTranscript += (fullTranscript.isEmpty ? "" : " ") + result.text
                transition(to: .processingFile(progress: min(1.0, Double(fullTranscript.count) / 100.0)))
            }
            if provider.state == .idle || provider.state == .stopped {
                fileContinuation.finish()
                break
            }
        }

        await recognitionService.stopTranscribing()
        resultsContinuation = previousContinuation
        activeProvider = nil
        transition(to: .idle)
        logger.info("File transcription complete. Characters: \(fullTranscript.count)")
        return fullTranscript
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

    private func requestPermissionsOrThrow() async throws {
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else { throw TranscriptionError.microphonePermissionDenied }

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
        delegate?.didReceivePartialResult(result.text)
        resultsContinuation?.yield(result)
    }

    public func recognitionService(_ service: SpeechRecognitionService, didReceiveFinalResult result: TranscriptionResult) {
        currentTranscript = result.text
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
}
