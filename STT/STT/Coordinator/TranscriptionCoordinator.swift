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
@MainActor
public final class TranscriptionCoordinator: ObservableObject {

    // MARK: - Public State

    @Published public private(set) var state: TranscriptionState = .idle
    @Published public private(set) var currentTranscript: String = ""
    @Published public private(set) var currentRoute: AudioRoute = .builtInMic
    @Published public private(set) var currentLocale: Locale

    public var isTranscribing: Bool { state.isActive }

    /// Delegation interface. Set before calling `startLiveTranscription()`.
    public weak var delegate: TranscriptionDelegate?

    // MARK: - AsyncSequence API

    public private(set) lazy var results: AsyncStream<TranscriptionResult> = {
        AsyncStream { continuation in
            self.resultsContinuation = continuation
        }
    }()
    private var resultsContinuation: AsyncStream<TranscriptionResult>.Continuation?

    // MARK: - Available Locales

    /// All locales the on-device recognizer supports, for display in the language picker.
    public var availableLocales: [Locale] {
        SpeechTranscriber.supportedLocales
    }

    // MARK: - Dependencies (injected)

    private let sessionManager: AudioSessionManager
    private let recognitionService: SpeechRecognitionService
    private let captureServiceFactory: () -> any AudioInputProvider
    private let fileServiceFactory: (URL) -> any AudioInputProvider

    private var activeProvider: (any AudioInputProvider)?
    private let logger = Logger(subsystem: "com.stt.module", category: "TranscriptionCoordinator")

    // MARK: - Init

    /// - Parameters:
    ///   - sessionManager: Manages the `AVAudioSession`.
    ///   - recognitionService: Manages `SpeechAnalyzer` + `SpeechTranscriber`.
    ///   - captureServiceFactory: Returns a fresh `AudioCaptureService` for live mic sessions.
    ///   - fileServiceFactory: Returns a fresh `FileCaptureService` for the given URL.
    ///   - locale: Initial locale. Defaults to auto-detected from device + UserDefaults.
    public init(
        sessionManager: AudioSessionManager,
        recognitionService: SpeechRecognitionService,
        captureServiceFactory: @escaping () -> any AudioInputProvider = { AudioCaptureService() },
        fileServiceFactory: @escaping (URL) -> any AudioInputProvider = { FileCaptureService(fileURL: $0) },
        locale: Locale? = nil
    ) {
        self.sessionManager = sessionManager
        self.recognitionService = recognitionService
        self.captureServiceFactory = captureServiceFactory
        self.fileServiceFactory = fileServiceFactory

        let savedOverride = UserDefaults.standard.string(forKey: localeDefaultsKey)
        self.currentLocale = locale ?? SpeechRecognitionService.resolveLocale(userOverride: savedOverride)

        sessionManager.delegate = self
        recognitionService.delegate = self
    }

    /// Convenience initializer with no external dependencies.
    public convenience init() {
        let savedOverride = UserDefaults.standard.string(forKey: localeDefaultsKey)
        let locale = SpeechRecognitionService.resolveLocale(userOverride: savedOverride)
        let recognitionService = SpeechRecognitionService(locale: locale)

        self.init(
            sessionManager: AudioSessionManager(),
            recognitionService: recognitionService,
            locale: locale
        )
    }

    // MARK: - Permission Check

    /// Checks both microphone and speech recognition permissions without requesting them.
    ///
    /// - Returns: A `PermissionStatus` indicating which (if any) permissions are missing.
    public func checkPermissions() async -> PermissionStatus {
        let micStatus = AVAudioApplication.shared.recordPermission
        let speechStatus = SFSpeechRecognizer.authorizationStatus()

        let micGranted = micStatus == .granted
        let speechGranted = speechStatus == .authorized

        switch (micGranted, speechGranted) {
        case (true, true):  return .granted
        case (false, true): return .microphoneDenied
        case (true, false): return .speechRecognitionDenied
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
        guard state == .idle || state == .stopped else { return }

        transition(to: .requestingPermissions)
        try await requestPermissionsOrThrow()
        transition(to: .preparingAudio)

        try sessionManager.configure()
        currentRoute = sessionManager.currentRoute
        currentTranscript = ""

        let provider = captureServiceFactory()
        activeProvider = provider

        try await recognitionService.startTranscribing(from: provider)
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

    /// Transcribes an audio file synchronously and returns the full transcript.
    ///
    /// - Parameter url: Path to the audio file (m4a, wav, mp3, caf).
    /// - Returns: The complete transcribed text.
    /// - Throws: `TranscriptionError.fileNotFound` if the URL is inaccessible.
    /// - Throws: `TranscriptionError.unsupportedAudioFormat` if the file format is incompatible.
    /// - Throws: `TranscriptionError.analyzerFailed` on recognition failure.
    public func transcribeFile(at url: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.fileNotFound(url)
        }

        transition(to: .requestingPermissions)
        try await requestPermissionsOrThrow()
        transition(to: .processingFile(progress: 0.0))

        currentTranscript = ""
        var fullTranscript = ""

        let provider = fileServiceFactory(url)
        activeProvider = provider

        // Collect results via an async stream bridge.
        let resultStream = AsyncStream<TranscriptionResult> { [weak self] continuation in
            self?.resultsContinuation = continuation
        }

        try await recognitionService.startTranscribing(from: provider)
        transition(to: .processingFile(progress: 0.1))

        for await result in resultStream {
            if result.isFinal {
                fullTranscript += (fullTranscript.isEmpty ? "" : " ") + result.text
                transition(to: .processingFile(progress: min(1.0, Double(fullTranscript.count) / 100.0)))
            }
            if provider.state == .idle || provider.state == .stopped { break }
        }

        await recognitionService.stopTranscribing()
        activeProvider = nil
        transition(to: .idle)
        logger.info("File transcription complete. Characters: \(fullTranscript.count)")
        return fullTranscript
    }

    // MARK: - Locale Switching

    /// Switches the active transcription locale.
    ///
    /// Saves the selection to `UserDefaults` and restarts the recognizer if active.
    ///
    /// - Parameter identifier: BCP-47 locale string (e.g. "hi-IN", "en-US").
    /// - Throws: `TranscriptionError.localeNotSupported` if no model exists for this locale.
    public func switchLocale(to identifier: String) async throws {
        try await recognitionService.switchLocale(to: identifier)
        if let matched = SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
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

    private func requestPermissionsOrThrow() async throws {
        let micStatus = await AVAudioApplication.requestRecordPermission()
        guard micStatus else { throw TranscriptionError.microphonePermissionDenied }

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
        logger.info("Route changed to: \(route.name)")
    }

    public func audioSessionManagerWasInterrupted(_ manager: AudioSessionManager) {
        if state == .transcribing {
            stopLiveTranscription()
        }
    }

    public func audioSessionManagerInterruptionEnded(_ manager: AudioSessionManager, shouldResume: Bool) {
        if shouldResume {
            Task { try? await startLiveTranscription() }
        }
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
