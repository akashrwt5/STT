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
        logger.info("━━━ startTranscribing called. Preset: \(String(describing: preset)), initial locale: \(self.currentLocale.identifier(.bcp47))")

        // ── 1. Locale resolution ──────────────────────────────────────────────
        logger.info("[1/6] Resolving locale for: \(self.currentLocale.identifier(.bcp47))")
        let resolvedLocale = try await resolveTranscriberLocale(currentLocale)
        logger.info("[1/6] Locale resolved → \(resolvedLocale.identifier(.bcp47))")

        // ── 2. Transcriber creation ───────────────────────────────────────────
        logger.info("[2/6] Creating SpeechTranscriber with locale: \(resolvedLocale.identifier(.bcp47)), preset: \(String(describing: preset))")
        let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: preset)
        self.transcriber = transcriber
        logger.info("[2/6] SpeechTranscriber created.")

        // ── 3. Model asset installation ───────────────────────────────────────
        logger.info("[3/6] Ensuring model assets are installed and allocated…")
        try await ensureModelInstalled(for: transcriber, locale: resolvedLocale)
        logger.info("[3/6] Model asset check complete.")

        // ── 4. Analyzer creation + audio format ───────────────────────────────
        logger.info("[4/6] Creating SpeechAnalyzer…")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        logger.info("[4/6] SpeechAnalyzer created.")

        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        if let fmt = analyzerFormat {
            logger.info("[4/6] Analyzer required format → sampleRate: \(fmt.sampleRate) Hz, channels: \(fmt.channelCount), commonFormat: \(fmt.commonFormat.rawValue), interleaved: \(fmt.isInterleaved)")
        } else {
            logger.warning("[4/6] bestAvailableAudioFormat returned nil — will pass provider buffers as-is.")
        }

        // ── 5. Feed task (raw buffers → AnalyzerInput) ────────────────────────
        logger.info("[5/6] Setting up buffer feed pipeline…")
        let (analyzerInputSequence, analyzerInputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        let rawBufferStream = provider.start()
        let converter = BufferConverter()
        var bufferCount = 0

        feedTask = Task { [weak self] in
            guard let self else { return }
            self.logger.info("[Feed] Feed task started.")
            for await buffer in rawBufferStream {
                guard !Task.isCancelled else {
                    self.logger.info("[Feed] Feed task cancelled — breaking buffer loop.")
                    break
                }
                do {
                    let outputBuffer: AVAudioPCMBuffer
                    if let analyzerFormat {
                        outputBuffer = try converter.convert(buffer, to: analyzerFormat)
                    } else {
                        outputBuffer = buffer
                    }
                    bufferCount += 1
                    if bufferCount == 1 || bufferCount % 50 == 0 {
                        self.logger.info("[Feed] Buffer #\(bufferCount) → frameLength: \(outputBuffer.frameLength), format: \(outputBuffer.format.sampleRate) Hz")
                    }
                    analyzerInputBuilder.yield(AnalyzerInput(buffer: outputBuffer))
                } catch {
                    self.logger.error("[Feed] Buffer conversion failed at buffer #\(bufferCount): \(error)")
                }
            }
            self.logger.info("[Feed] Raw buffer stream exhausted. Total buffers fed: \(bufferCount). Finishing analyzer input stream.")
            analyzerInputBuilder.finish()
        }
        logger.info("[5/6] Feed task started.")

        // ── 6. Analysis task (run analyzer + consume results) ─────────────────
        logger.info("[6/6] Starting analysis task…")
        analysisTask = Task { [weak self] in
            guard let self else { return }
            self.logger.info("[Analysis] Analysis task started. Entering withThrowingTaskGroup…")
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        self.logger.info("[Analyzer] analyzer.start() called — feeding input sequence to SpeechAnalyzer.")
                        try await analyzer.start(inputSequence: analyzerInputSequence)
                        self.logger.info("[Analyzer] analyzer.start() returned (input sequence exhausted).")
                    }

                    // `transcriber.results` is an async property in iOS 26.
                    self.logger.info("[Results] Awaiting transcriber.results async property…")
                    let resultStream = await transcriber.results
                    self.logger.info("[Results] Got result stream. Starting iteration…")

                    var resultCount = 0
                    for try await result in resultStream {
                        guard !Task.isCancelled else {
                            self.logger.info("[Results] Task cancelled — breaking result loop.")
                            break
                        }
                        resultCount += 1
                        let plainText = String(result.text.characters)
                        self.logger.info("[Results] Result #\(resultCount): isFinal=\(result.isFinal), text='\(plainText)'")

                        let transcriptionResult = TranscriptionResult(
                            text: plainText,
                            isFinal: result.isFinal,
                            locale: self.currentLocale,
                            confidence: nil
                        )

                        await MainActor.run {
                            if result.isFinal {
                                self.logger.info("[Delegate] Calling didReceiveFinalResult: '\(plainText)'")
                                self.delegate?.recognitionService(self, didReceiveFinalResult: transcriptionResult)
                            } else {
                                self.logger.info("[Delegate] Calling didReceivePartialResult: '\(plainText)'")
                                self.delegate?.recognitionService(self, didReceivePartialResult: transcriptionResult)
                            }
                        }
                    }
                    self.logger.info("[Results] Result stream exhausted. Total results received: \(resultCount).")
                    group.cancelAll()
                }
            } catch {
                self.logger.error("[Analysis] Analysis task failed with error: \(error)")
                await MainActor.run {
                    self.delegate?.recognitionService(self, didFailWith: .analyzerFailed(error))
                }
            }
            self.logger.info("[Analysis] Analysis task complete. Cancelling feed task.")
            self.feedTask?.cancel()
        }
        logger.info("━━━ startTranscribing setup complete. Pipeline is running.")
    }

    /// Stops transcription and cancels in-flight tasks.
    ///
    /// `SpeechAnalyzer` has no explicit `stop()` — finishing the input stream and
    /// cancelling the tasks is the correct teardown.
    public func stopTranscribing() async {
        logger.info("stopTranscribing called.")
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
        logger.info("switchLocale called with identifier: \(identifier)")
        let newLocale = try await resolveTranscriberLocale(Locale(identifier: identifier))
        currentLocale = newLocale
        logger.info("Locale switched to: \(newLocale.identifier(.bcp47))")
    }

    // MARK: - Asset Installation

    /// Ensures the on-device model assets for `locale` are installed and allocated.
    ///
    /// Always calls `AssetInventory.assetInstallationRequest` regardless of
    /// `installedLocales` — "installed" does not guarantee "allocated", and the
    /// system is idempotent (returns nil when nothing is needed).
    private func ensureModelInstalled(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        // Log current installed locales for diagnostics (not used as a gate).
        let installedLocales = await SpeechTranscriber.installedLocales
        let installedIDs = installedLocales.map { $0.identifier(.bcp47) }
        logger.info("[Assets] installedLocales (\(installedLocales.count)): \(installedIDs.joined(separator: ", "))")
        logger.info("[Assets] Target locale: \(locale.identifier(.bcp47)) — listed in installedLocales: \(installedIDs.contains(locale.identifier(.bcp47)))")

        // Always request asset installation — system returns nil when nothing to do.
        logger.info("[Assets] Calling AssetInventory.assetInstallationRequest(supporting: [transcriber])…")
        do {
            let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
            if let request {
                logger.info("[Assets] Installation request returned non-nil — downloading and installing assets for \(locale.identifier(.bcp47))…")
                try await request.downloadAndInstall()
                logger.info("[Assets] downloadAndInstall() completed for \(locale.identifier(.bcp47)).")
            } else {
                logger.info("[Assets] AssetInventory returned nil request — assets already present and allocated for \(locale.identifier(.bcp47)).")
            }
        } catch {
            logger.error("[Assets] Asset installation failed for \(locale.identifier(.bcp47)): \(error)")
            throw TranscriptionError.analyzerFailed(error)
        }
    }

    // MARK: - Locale Resolution

    /// Resolves the best supported locale equivalent to the given candidate.
    ///
    /// `SpeechTranscriber.supportedLocale(equivalentTo:)` is `async` in iOS 26.
    private func resolveTranscriberLocale(_ candidate: Locale) async throws -> Locale {
        logger.info("[Locale] Querying SpeechTranscriber.supportedLocale(equivalentTo: \(candidate.identifier(.bcp47)))…")
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
            logger.info("[Locale] Matched supported locale: \(match.identifier(.bcp47))")
            return match
        }
        logger.error("[Locale] No supported locale found for: \(candidate.identifier(.bcp47))")
        throw TranscriptionError.localeNotSupported(candidate.identifier)
    }
}

// MARK: - Locale Auto-Detection

extension SpeechRecognitionService {
    /// Resolves the best locale for the current device context.
    ///
    /// Priority: user override → device locale → device language → en-IN fallback.
    public static func resolveLocale(userOverride: String? = nil) async -> Locale {
        let logger = Logger(subsystem: "com.stt.module", category: "SpeechRecognitionService")
        logger.info("[resolveLocale] Starting. userOverride=\(userOverride ?? "nil"), device=\(Locale.current.identifier(.bcp47))")

        if let override = userOverride,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: override)) {
            logger.info("[resolveLocale] Using user override: \(supported.identifier(.bcp47))")
            return supported
        }

        if let deviceMatch = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            logger.info("[resolveLocale] Using device locale match: \(deviceMatch.identifier(.bcp47))")
            return deviceMatch
        }

        let allLocales = await SpeechTranscriber.supportedLocales
        logger.info("[resolveLocale] Device locale not matched. Checking language code. All supported count: \(allLocales.count)")
        if let langCode = Locale.current.language.languageCode?.identifier,
           let langMatch = allLocales.first(where: { $0.language.languageCode?.identifier == langCode }) {
            logger.info("[resolveLocale] Language code match: \(langMatch.identifier(.bcp47))")
            return langMatch
        }

        let fallback = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-IN"))
            ?? allLocales.first
            ?? Locale(identifier: "en-IN")
        logger.info("[resolveLocale] Falling back to: \(fallback.identifier(.bcp47))")
        return fallback
    }
}
