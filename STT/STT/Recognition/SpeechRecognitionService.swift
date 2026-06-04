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
public final class SpeechRecognitionService: @unchecked Sendable {

    // MARK: - Public

    public weak var delegate: SpeechRecognitionServiceDelegate?

    // MARK: - Private

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var currentLocale: Locale
    private var analysisTask: Task<Void, Never>?
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
    ///   - preset: Recognition profile. Use `.progressiveTranscription` for live mic
    ///     (yields partial results immediately) and `.transcription` for file input
    ///     (optimises for accuracy over a complete audio buffer).
    /// - Throws: `TranscriptionError.localeNotSupported` if the locale has no model.
    /// - Throws: `TranscriptionError.analyzerFailed` if the analyzer cannot start.
    public func startTranscribing(
        from provider: any AudioInputProvider,
        preset: SpeechTranscriber.Preset = .progressiveTranscription
    ) async throws {
        let resolvedLocale = try await resolveTranscriberLocale(currentLocale)

        let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: preset)
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let audioStream = provider.start()

        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Run the analyzer and result iteration concurrently.
                // `analyzer.start(inputSequence:)` feeds audio; `transcriber.results`
                // is the async property that vends the recognition output stream.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await analyzer.start(inputSequence: audioStream)
                    }
                    // `transcriber.results` is an async property in iOS 26 —
                    // must be awaited before iterating.
                    let resultStream = await transcriber.results
                    for await result in resultStream {
                        guard !Task.isCancelled else { break }
                        // `result.text` is an `AttributedString` in iOS 26 —
                        // flatten to a plain String via its character view.
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
                logger.error("Analysis task failed: \(error)")
                await MainActor.run {
                    self.delegate?.recognitionService(self, didFailWith: .analyzerFailed(error))
                }
            }
        }

        logger.info("SpeechRecognitionService started with locale: \(resolvedLocale.identifier)")
    }

    /// Stops transcription and cancels any in-flight analysis task.
    ///
    /// `SpeechAnalyzer` has no explicit `stop()` method — stopping the input stream and
    /// cancelling the analysis task is the correct teardown sequence.
    public func stopTranscribing() async {
        analysisTask?.cancel()
        await analysisTask?.value
        analysisTask = nil
        analyzer = nil
        transcriber = nil
        logger.info("SpeechRecognitionService stopped.")
    }

    /// Switches to a new locale by updating the stored locale for the next session.
    ///
    /// - Parameter identifier: BCP-47 locale identifier (e.g. "en-IN", "hi-IN").
    /// - Throws: `TranscriptionError.localeNotSupported` if no matching model exists.
    public func switchLocale(to identifier: String) async throws {
        let newLocale = try await resolveTranscriberLocale(Locale(identifier: identifier))
        currentLocale = newLocale
        logger.info("Locale switched to: \(newLocale.identifier)")
    }

    // MARK: - Locale Resolution

    /// Resolves the best supported locale equivalent to the given candidate.
    ///
    /// `SpeechTranscriber.supportedLocale(equivalentTo:)` is `async` in iOS 26 because
    /// it may trigger model availability checks.
    ///
    /// - Throws: `TranscriptionError.localeNotSupported` if no match found.
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
    /// `async` because `SpeechTranscriber.supportedLocales` and
    /// `supportedLocale(equivalentTo:)` are async in iOS 26.
    ///
    /// Priority: user override → device locale → device language → en-IN fallback.
    public static func resolveLocale(userOverride: String? = nil) async -> Locale {
        // 1. User-selected language
        if let override = userOverride,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: override)) {
            return supported
        }

        // 2. Device locale
        if let deviceMatch = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return deviceMatch
        }

        // 3. Language component only
        let allLocales = await SpeechTranscriber.supportedLocales
        if let langCode = Locale.current.language.languageCode?.identifier,
           let langMatch = allLocales.first(where: { $0.language.languageCode?.identifier == langCode }) {
            return langMatch
        }

        // 4. Fallback to en-IN
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-IN"))
            ?? allLocales.first
            ?? Locale(identifier: "en-IN")
    }
}
