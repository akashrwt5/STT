// SpeechRecognitionService.swift
// STT
//
// Single responsibility: SpeechAnalyzer + SpeechTranscriber lifecycle and result iteration.

import AVFoundation
import Speech
import os.log

/// Callback interface for speech recognition events.
public protocol SpeechRecognitionServiceDelegate: AnyObject {
    func recognitionService(_ service: SpeechRecognitionService, didReceivePartialResult result: TranscriptionResult)
    func recognitionService(_ service: SpeechRecognitionService, didReceiveFinalResult result: TranscriptionResult)
    func recognitionService(_ service: SpeechRecognitionService, didFailWith error: TranscriptionError)
}

/// Owns `SpeechAnalyzer` and `SpeechTranscriber` setup, lifecycle, and result iteration.
///
/// Accepts audio from any `AudioInputProvider` — it is agnostic to the audio source.
/// It is also the only component that knows the analyzer's required audio format, so
/// it performs the conversion from each provider's raw buffers.
public final class SpeechRecognitionService: @unchecked Sendable {

    // MARK: - Public

    public weak var delegate: SpeechRecognitionServiceDelegate?

    // MARK: - Private

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var currentLocale: Locale
    private var analysisTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.stt.module", category: "SpeechRecognitionService")

    // MARK: - Init

    public init(locale: Locale) {
        self.currentLocale = locale
    }

    // MARK: - Transcription

    /// Begins transcribing audio from the given provider.
    ///
    /// - Parameters:
    ///   - provider: Any `AudioInputProvider` — mic or file.
    ///   - preset: Recognition profile. `.progressiveTranscription` for live mic,
    ///     `.transcription` for file input.
    /// - Throws: `TranscriptionError.localeNotSupported` if the locale has no model.
    /// - Throws: `TranscriptionError.analyzerFailed` if the analyzer cannot start.
    public func startTranscribing(
        from provider: any AudioInputProvider,
        preset: SpeechTranscriber.Preset = .progressiveTranscription
    ) async throws {
        let resolvedLocale = try await resolveTranscriberLocale(currentLocale)

        let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: preset)
        self.transcriber = transcriber

        // CRITICAL: install/allocate the locale's model assets before use, otherwise
        // SpeechAnalyzer logs "Cannot use modules with unallocated locales" and fails.
        try await ensureModelInstalled(for: transcriber, locale: resolvedLocale)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // The analyzer dictates the required audio format (commonly 16-bit Int PCM).
        // Feeding any other format triggers a runtime precondition crash.
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        // Bridge raw provider buffers → converted AnalyzerInput buffers.
        let (analyzerInputSequence, analyzerInputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        let rawBufferStream = provider.start()
        let converter = BufferConverter()

        feedTask = Task { [weak self] in
            for await buffer in rawBufferStream {
                guard !Task.isCancelled else { break }
                do {
                    let outputBuffer: AVAudioPCMBuffer
                    if let analyzerFormat {
                        outputBuffer = try converter.convert(buffer, to: analyzerFormat)
                    } else {
                        outputBuffer = buffer
                    }
                    analyzerInputBuilder.yield(AnalyzerInput(buffer: outputBuffer))
                } catch {
                    self?.logger.error("Buffer conversion failed: \(error)")
                }
            }
            analyzerInputBuilder.finish()
        }

        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await analyzer.start(inputSequence: analyzerInputSequence)
                    }

                    // `transcriber.results` is an async property in iOS 26.
                    let resultStream = await transcriber.results
                    for try await result in resultStream {
                        guard !Task.isCancelled else { break }
                        // `result.text` is an AttributedString — flatten to plain text.
                        let plainText = String(result.text.characters)
                        let transcriptionResult = TranscriptionResult(
                            text: plainText,
                            isFinal: result.isFinal,
                            locale: self.currentLocale,
                            confidence: nil
                        )
                        await MainActor.run {
                            if result.isFinal {
                                self.delegate?.recognitionService(self, didReceiveFinalResult: transcriptionResult)
                            } else {
                                self.delegate?.recognitionService(self, didReceivePartialResult: transcriptionResult)
                            }
                        }
                    }
                    group.cancelAll()
                }
            } catch {
                self.logger.error("Analysis task failed: \(error)")
                await MainActor.run {
                    self.delegate?.recognitionService(self, didFailWith: .analyzerFailed(error))
                }
            }
            self.feedTask?.cancel()
        }

        logger.info("SpeechRecognitionService started with locale: \(resolvedLocale.identifier(.bcp47))")
    }

    /// Stops transcription and cancels in-flight tasks.
    ///
    /// `SpeechAnalyzer` has no explicit `stop()` — finishing the input stream and
    /// cancelling the tasks is the correct teardown.
    public func stopTranscribing() async {
        feedTask?.cancel()
        analysisTask?.cancel()
        await analysisTask?.value
        feedTask = nil
        analysisTask = nil
        analyzer = nil
        transcriber = nil
        logger.info("SpeechRecognitionService stopped.")
    }

    /// Switches to a new locale for the next session.
    ///
    /// - Parameter identifier: BCP-47 locale identifier (e.g. "en-IN", "hi-IN").
    /// - Throws: `TranscriptionError.localeNotSupported` if no matching model exists.
    public func switchLocale(to identifier: String) async throws {
        let newLocale = try await resolveTranscriberLocale(Locale(identifier: identifier))
        currentLocale = newLocale
        logger.info("Locale switched to: \(newLocale.identifier(.bcp47))")
    }

    // MARK: - Asset Installation

    /// Ensures the on-device model assets for `locale` are installed and allocated.
    ///
    /// The system downloads SpeechAnalyzer models on first use. Without this step the
    /// analyzer reports "Cannot use modules with unallocated locales" and produces no output.
    private func ensureModelInstalled(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        // If already installed, nothing to do.
        let installed = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        if installed.contains(locale.identifier(.bcp47)) {
            return
        }

        // Request download + installation of any assets the transcriber needs.
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                logger.info("Downloading speech model for \(locale.identifier(.bcp47))…")
                try await request.downloadAndInstall()
                logger.info("Speech model installed for \(locale.identifier(.bcp47)).")
            }
        } catch {
            logger.error("Model installation failed: \(error)")
            throw TranscriptionError.analyzerFailed(error)
        }
    }

    // MARK: - Locale Resolution

    /// Resolves the best supported locale equivalent to the given candidate.
    ///
    /// `SpeechTranscriber.supportedLocale(equivalentTo:)` is `async` in iOS 26.
    private func resolveTranscriberLocale(_ candidate: Locale) async throws -> Locale {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
            return match
        }
        throw TranscriptionError.localeNotSupported(candidate.identifier)
    }
}

// MARK: - Locale Auto-Detection

extension SpeechRecognitionService {
    /// Resolves the best locale for the current device context.
    ///
    /// Priority: user override → device locale → device language → en-IN fallback.
    public static func resolveLocale(userOverride: String? = nil) async -> Locale {
        if let override = userOverride,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: override)) {
            return supported
        }

        if let deviceMatch = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return deviceMatch
        }

        let allLocales = await SpeechTranscriber.supportedLocales
        if let langCode = Locale.current.language.languageCode?.identifier,
           let langMatch = allLocales.first(where: { $0.language.languageCode?.identifier == langCode }) {
            return langMatch
        }

        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-IN"))
            ?? allLocales.first
            ?? Locale(identifier: "en-IN")
    }
}
