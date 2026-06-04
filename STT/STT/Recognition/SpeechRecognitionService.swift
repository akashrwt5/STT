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

    /// All locales supported by the on-device recognizer.
    public var availableLocales: [Locale] {
        SpeechTranscriber.supportedLocales
    }

    // MARK: - Private

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var currentLocale: Locale
    private var analysisTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.stt.module", category: "SpeechRecognitionService")

    // MARK: - Init

    /// - Parameter locale: Initial locale. Use `resolveLocale(userOverride:)` from the coordinator.
    public init(locale: Locale) {
        self.currentLocale = locale
    }

    // MARK: - Transcription

    /// Begins transcribing audio from the given provider.
    ///
    /// - Parameter provider: Any `AudioInputProvider` — mic or file.
    /// - Throws: `TranscriptionError.deviceNotSupported` if the device cannot run on-device STT.
    /// - Throws: `TranscriptionError.localeNotSupported` if the locale has no model.
    /// - Throws: `TranscriptionError.analyzerFailed` if the analyzer cannot start.
    public func startTranscribing(from provider: any AudioInputProvider) async throws {
        guard SpeechTranscriber.supportsDevice() else {
            throw TranscriptionError.deviceNotSupported
        }

        let resolvedLocale = try resolveTranscriberLocale(currentLocale)
        let transcriber = SpeechTranscriber(locale: resolvedLocale)
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let audioStream = provider.start()

        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let _ = analyzer.start(inputSequence: audioStream)

                for await result in transcriber.results {
                    guard !Task.isCancelled else { break }

                    let transcriptionResult = TranscriptionResult(
                        text: result.text,
                        isFinal: result.isFinal,
                        locale: self.currentLocale,
                        confidence: result.confidence.map { Float($0) }
                    )

                    await MainActor.run {
                        if result.isFinal {
                            self.delegate?.recognitionService(self, didReceiveFinalResult: transcriptionResult)
                        } else {
                            self.delegate?.recognitionService(self, didReceivePartialResult: transcriptionResult)
                        }
                    }
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
    public func stopTranscribing() async {
        analysisTask?.cancel()
        analysisTask = nil
        await analyzer?.stop()
        analyzer = nil
        transcriber = nil
        logger.info("SpeechRecognitionService stopped.")
    }

    /// Switches to a new locale by tearing down and reinitializing the transcriber.
    ///
    /// - Parameter identifier: BCP-47 locale identifier (e.g. "en-IN", "hi-IN").
    /// - Throws: `TranscriptionError.localeNotSupported` if no matching model exists.
    public func switchLocale(to identifier: String) async throws {
        let newLocale = try resolveTranscriberLocale(Locale(identifier: identifier))
        currentLocale = newLocale
        logger.info("Locale switched to: \(newLocale.identifier)")
    }

    // MARK: - Locale Resolution

    /// Resolves the best supported locale equivalent to the given candidate.
    ///
    /// - Throws: `TranscriptionError.localeNotSupported` if no match found.
    private func resolveTranscriberLocale(_ candidate: Locale) throws -> Locale {
        if let match = SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
            return match
        }
        throw TranscriptionError.localeNotSupported(candidate.identifier)
    }
}

// MARK: - Locale Auto-Detection

extension SpeechRecognitionService {
    /// Resolves the best locale for the current device context.
    ///
    /// Priority: user override → device locale → device language component → en-IN fallback.
    ///
    /// - Parameter userOverride: BCP-47 identifier stored in `UserDefaults`, if any.
    /// - Returns: A `Locale` guaranteed to be supported by `SpeechTranscriber`.
    public static func resolveLocale(userOverride: String? = nil) -> Locale {
        // 1. User-selected language
        if let override = userOverride,
           let supported = SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: override)) {
            return supported
        }

        // 2. Device locale
        if let deviceMatch = SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return deviceMatch
        }

        // 3. Language component only
        if let langCode = Locale.current.language.languageCode?.identifier,
           let langMatch = SpeechTranscriber.supportedLocales.first(where: {
               $0.language.languageCode?.identifier == langCode
           }) {
            return langMatch
        }

        // 4. Fallback to en-IN
        return SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-IN"))
            ?? SpeechTranscriber.supportedLocales.first
            ?? Locale(identifier: "en-IN")
    }
}
