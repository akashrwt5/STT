// SpeechRecognitionService.swift
// STT
//
// Single responsibility: SpeechAnalyzer + SpeechTranscriber lifecycle and result iteration.

import AVFoundation
import Speech
import os.log

/// Callback interface for speech recognition events. Called on the main actor.
@MainActor
public protocol SpeechRecognitionServiceDelegate: AnyObject {
    func recognitionService(_ service: SpeechRecognitionService, didReceivePartialResult result: TranscriptionResult)
    func recognitionService(_ service: SpeechRecognitionService, didReceiveFinalResult result: TranscriptionResult)
    func recognitionService(_ service: SpeechRecognitionService, didFailWith error: TranscriptionError)
    /// Called when the result stream completes normally (e.g. an input file is fully
    /// consumed). Not called when the session is cancelled or fails.
    func recognitionServiceDidComplete(_ service: SpeechRecognitionService)

    /// Called when the silence detector determines the session should end (the user
    /// stopped speaking, or never spoke). Only fired when silence detection is enabled.
    func recognitionServiceDidDetectSilence(_ service: SpeechRecognitionService)
}

/// Owns `SpeechAnalyzer` and `SpeechTranscriber` setup, lifecycle, and result iteration.
///
/// Accepts audio from any `AudioInputProvider` — it is agnostic to the audio source.
/// It is also the only component that knows the analyzer's required audio format, so
/// it performs the conversion from each provider's raw buffers.
///
/// Main-actor isolated, consistent with the rest of the module. The heavy work
/// (buffer conversion, analyzer execution, result iteration) happens inside child
/// tasks that suspend on `await`, so the main thread is never blocked.
@MainActor
public final class SpeechRecognitionService {

    // MARK: - Public

    public weak var delegate: SpeechRecognitionServiceDelegate?

    // MARK: - Private

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var currentLocale: Locale
    private var analysisTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?

    /// Pre-warmed pair cached by `prewarm()`. Consumed on the first `startTranscribing`
    /// so that call skips the entire model-install + transcriber/analyzer creation path.
    private var prewarmedTranscriber: SpeechTranscriber?
    private var prewarmedAnalyzer: SpeechAnalyzer?
    private var prewarmedLocale: Locale?
    /// The in-flight prewarm. `startTranscribing` awaits this so a tap that lands while
    /// prewarm is still running reuses its result instead of starting a *competing*
    /// model install/reserve for the same locale (concurrent AssetInventory access
    /// on one locale can stall — that race was the first-tap hang).
    private var prewarmTask: Task<Void, Never>?
    /// Incremented on every `startTranscribing`. A finishing analysis task only touches
    /// shared state (`feedTask`, completion delegate) if its captured generation still
    /// matches — so a stale, slow-to-finish task can never cancel a *newer* session's
    /// feed task or fire a spurious completion.
    private var generation = 0
    /// Set once the transcriber commits its first final result. Read by the silence
    /// detector as a guardrail: end-of-speech silence only ends the session after a
    /// complete utterance, so a mid-sentence pause never cuts the user off.
    private var hasReceivedFinalResult = false
    private let logger = Logger(subsystem: "com.stt.module", category: "SpeechRecognitionService")

    // MARK: - Init

    public init(locale: Locale) {
        self.currentLocale = locale
    }

    // MARK: - Pre-warm

    /// Kicks off the expensive one-time setup (locale resolution, model install/reserve,
    /// SpeechTranscriber + SpeechAnalyzer creation) in the background at launch so the
    /// first mic tap finds everything ready. Returns immediately; the work runs in a
    /// stored task that `startTranscribing` awaits.
    ///
    /// Idempotent — a second call while a prewarm is in flight (or already done) no-ops.
    public func prewarm() {
        guard prewarmTask == nil else { return }
        prewarmTask = Task { [weak self] in await self?.performPrewarm() }
    }

    private func performPrewarm() async {
        #if DEBUG
        let probePrewarmStart = MemoryProbe.snapshot(label: "prewarm START")
        #endif

        let savedOverride = UserDefaults.standard.string(forKey: "stt.userSelectedLocale")
        guard let resolvedLocale = try? await resolveTranscriberLocale(
            await SpeechRecognitionService.resolveLocale(userOverride: savedOverride)
        ) else {
            logger.warning("[Prewarm] Locale resolution failed — first tap will run full setup.")
            return
        }

        // Already warm for this locale? Nothing to do.
        if let cached = prewarmedLocale, cached.identifier(.bcp47) == resolvedLocale.identifier(.bcp47) {
            return
        }

        let t = SpeechTranscriber(locale: resolvedLocale, preset: .progressiveTranscription)
        do {
            try await ensureModelInstalled(for: t, locale: resolvedLocale)
        } catch {
            logger.error("[Prewarm] Model install failed: \(error) — first tap will retry.")
            return
        }

        let a = SpeechAnalyzer(modules: [t])
        prewarmedTranscriber = t
        prewarmedAnalyzer    = a
        prewarmedLocale      = resolvedLocale
        logger.info("[Prewarm] ✅ SpeechTranscriber + SpeechAnalyzer ready for \(resolvedLocale.identifier(.bcp47)).")

        #if DEBUG
        let probePrewarmEnd = MemoryProbe.snapshot(label: "prewarm END")
        MemoryProbe.logDiff(before: probePrewarmStart, after: probePrewarmEnd)
        #endif
    }

    // MARK: - Transcription

    /// Begins transcribing audio from the given provider.
    ///
    /// - Parameters:
    ///   - provider: Any `AudioInputProvider` — mic or file.
    ///   - preset: Recognition profile. `.progressiveTranscription` for live mic,
    ///     `.transcription` for file input.
    ///   - silenceConfiguration: When enabled, the session ends automatically after a
    ///     configurable period of silence. Defaults to `.disabled` (manual stop only).
    /// - Throws: `TranscriptionError.localeNotSupported` if the locale has no model.
    /// - Throws: `TranscriptionError.analyzerFailed` if the analyzer cannot start.
    public func startTranscribing(
        from provider: any AudioInputProvider,
        preset: SpeechTranscriber.Preset = .progressiveTranscription,
        silenceConfiguration: SilenceDetectionConfiguration = .disabled
    ) async throws {
        logger.info("━━━ startTranscribing called. Preset: \(String(describing: preset)), initial locale: \(self.currentLocale.identifier(.bcp47))")
        hasReceivedFinalResult = false
        generation += 1
        let myGeneration = generation

        // ── 1-4. Locale resolution, model install, transcriber + analyzer creation ──
        // Reuse the prewarmed pair when it matches the requested locale — avoids the
        // multi-second setup on the first tap. Falls back to the full path if prewarm
        // didn't complete in time or the locale changed.
        let resolvedLocale: Locale
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer

        // Wait for any in-flight prewarm to finish so we reuse its transcriber/analyzer
        // instead of starting a second, competing model install/reserve for the same
        // locale (which can stall on AssetInventory). If prewarm already finished or was
        // never started, this returns immediately.
        await prewarmTask?.value

        let targetLocale = try await resolveTranscriberLocale(currentLocale)
        if let pw = prewarmedTranscriber,
           let pa = prewarmedAnalyzer,
           let pl = prewarmedLocale,
           pl.identifier(.bcp47) == targetLocale.identifier(.bcp47) {
            logger.info("[1-4/6] ⚡ Using prewarmed SpeechTranscriber + SpeechAnalyzer for \(targetLocale.identifier(.bcp47)).")
            resolvedLocale = pl
            transcriber    = pw
            analyzer       = pa
            prewarmedTranscriber = nil
            prewarmedAnalyzer    = nil
            prewarmedLocale      = nil
        } else {
            logger.info("[1/6] Prewarm miss — running full setup for \(targetLocale.identifier(.bcp47)).")
            resolvedLocale = targetLocale
            let t = SpeechTranscriber(locale: resolvedLocale, preset: preset)
            logger.info("[3/6] Ensuring model assets are installed and allocated…")
            try await ensureModelInstalled(for: t, locale: resolvedLocale)
            logger.info("[3/6] Model asset check complete.")
            logger.info("[4/6] Creating SpeechAnalyzer…")
            let a = SpeechAnalyzer(modules: [t])
            logger.info("[4/6] SpeechAnalyzer created.")
            transcriber = t
            analyzer    = a
        }
        self.transcriber = transcriber
        self.analyzer    = analyzer

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
        let logger = self.logger

        // Silence detector (VAD). Measures buffer energy and signals when the session
        // should end after a configurable silence. Sample rate is taken from the
        // analyzer format the buffers are converted to (defaults to 16 kHz).
        let silenceDetector: SilenceDetector?
        if silenceConfiguration.isEnabled {
            silenceDetector = SilenceDetector(
                configuration: silenceConfiguration,
                sampleRate: analyzerFormat?.sampleRate ?? 16_000
            )
            logger.info("[Feed] Silence detection ENABLED (speechEnd: \(silenceConfiguration.speechEndTimeout)s, noSpeech: \(silenceConfiguration.noSpeechTimeout)s, threshold: \(silenceConfiguration.thresholdDBFS) dBFS).")
        } else {
            silenceDetector = nil
        }

        feedTask = Task { [weak self] in
            var bufferCount = 0
            logger.info("[Feed] Feed task started.")
            for await buffer in rawBufferStream {
                guard !Task.isCancelled else {
                    logger.info("[Feed] Feed task cancelled — breaking buffer loop.")
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
                        logger.info("[Feed] Buffer #\(bufferCount) → frameLength: \(outputBuffer.frameLength), format: \(outputBuffer.format.sampleRate) Hz")
                    }
                    analyzerInputBuilder.yield(AnalyzerInput(buffer: outputBuffer))

                    // VAD: end the session if enough silence has elapsed. We finish the
                    // input stream so the analyzer drains cleanly, then notify the
                    // delegate so the coordinator can tear down the live session.
                    if let silenceDetector,
                       case .silenceDetected(let reason) = silenceDetector.process(outputBuffer) {
                        // Guardrail (Phase 2): end-of-speech silence only ends the session
                        // once the transcriber has committed a final result — otherwise the
                        // user merely paused mid-utterance and we keep listening. The
                        // no-speech timeout always ends the session (nobody ever spoke).
                        let shouldStop: Bool
                        switch reason {
                        case .noSpeech:
                            shouldStop = true
                        case .endOfSpeech:
                            shouldStop = self?.hasReceivedFinalResult ?? true
                        }

                        guard shouldStop else {
                            // Pause without a committed utterance yet — keep listening.
                            continue
                        }

                        logger.info("[Feed] Silence confirmed (\(String(describing: reason))). Finishing input and notifying delegate.")
                        analyzerInputBuilder.finish()
                        if let self { self.delegate?.recognitionServiceDidDetectSilence(self) }
                        return
                    }
                } catch {
                    logger.error("[Feed] Buffer conversion failed at buffer #\(bufferCount): \(error)")
                }
            }
            logger.info("[Feed] Raw buffer stream exhausted. Total buffers fed: \(bufferCount). Finishing analyzer input stream.")
            analyzerInputBuilder.finish()
        }
        logger.info("[5/6] Feed task started.")

        // ── 6. Analysis task (run analyzer + consume results) ─────────────────
        logger.info("[6/6] Starting analysis task…")
        let locale = currentLocale
        analysisTask = Task { [weak self] in
            guard let self else { return }
            logger.info("[Analysis] Analysis task started. Entering withThrowingTaskGroup…")
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        logger.info("[Analyzer] analyzer.start() called — feeding input sequence to SpeechAnalyzer.")
                        try await analyzer.start(inputSequence: analyzerInputSequence)
                        logger.info("[Analyzer] analyzer.start() returned (input sequence exhausted).")

                        // Critical: starting the analyzer and exhausting the input
                        // sequence does NOT flush the transcriber's pending audio or
                        // close `transcriber.results`. Without finalizing, the results
                        // loop hangs forever waiting for output that never arrives.
                        //
                        // `finalizeAndFinishThroughEndOfInput()` drains all buffered
                        // audio into final results and then closes the results stream,
                        // which lets the results loop receive its output and terminate.
                        // This is correct for both file input (input ends when the file
                        // is fully read) and live mic (input ends when stop() finishes
                        // the buffer stream).
                        logger.info("[Analyzer] Finalizing analyzer through end of input…")
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                        logger.info("[Analyzer] finalizeAndFinishThroughEndOfInput() returned.")
                    }

                    // `transcriber.results` is an async property in iOS 26.
                    logger.info("[Results] Awaiting transcriber.results async property…")
                    let resultStream = await transcriber.results
                    logger.info("[Results] Got result stream. Starting iteration…")

                    var resultCount = 0
                    for try await result in resultStream {
                        guard !Task.isCancelled else {
                            logger.info("[Results] Task cancelled — breaking result loop.")
                            break
                        }
                        resultCount += 1
                        let plainText = String(result.text.characters)
                        let isFinal = result.isFinal
                        logger.info("[Results] Result #\(resultCount): isFinal=\(isFinal), text='\(plainText)'")

                        let transcriptionResult = TranscriptionResult(
                            text: plainText,
                            isFinal: isFinal,
                            locale: locale,
                            confidence: nil
                        )

                        // Already on the main actor — deliver directly.
                        if isFinal {
                            self.hasReceivedFinalResult = true
                            self.delegate?.recognitionService(self, didReceiveFinalResult: transcriptionResult)
                        } else {
                            self.delegate?.recognitionService(self, didReceivePartialResult: transcriptionResult)
                        }
                    }
                    logger.info("[Results] Result stream exhausted. Total results received: \(resultCount).")
                    group.cancelAll()
                }
                // Reached only on normal completion (input exhausted), not cancellation/error.
                // Guard with generation so a stale task can't fire completion for a session
                // that has already been replaced by a newer one.
                if !Task.isCancelled, self.generation == myGeneration {
                    self.delegate?.recognitionServiceDidComplete(self)
                }
            } catch {
                logger.error("[Analysis] Analysis task failed with error: \(error)")
                if self.generation == myGeneration {
                    self.delegate?.recognitionService(self, didFailWith: .analyzerFailed(error))
                }
            }
            logger.info("[Analysis] Analysis task complete. Cancelling feed task.")
            // Only cancel the feed task if it still belongs to *this* generation —
            // otherwise a slow stale task would kill a newer session's feed.
            if self.generation == myGeneration {
                self.feedTask?.cancel()
            }
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

    // MARK: - Manual Lifecycle (Diagnostic)

    /// Releases every speech-related ref held by this service. Pair with the
    /// MemoryProbe to verify whether the framework actually returns the dirty
    /// blocks to the OS when our handles drop.
    public func unload() async {
        logger.info("[Unload] Releasing speech state…")
        await stopTranscribing()
        prewarmedTranscriber = nil
        prewarmedAnalyzer    = nil
        prewarmedLocale      = nil
        prewarmTask          = nil
        logger.info("[Unload] Done.")
    }

    /// Kicks off a prewarm (if not already running) and awaits its completion.
    /// Used by the diagnostic Load button so probes can wrap a complete cycle.
    public func awaitPrewarm() async {
        prewarm()
        await prewarmTask?.value
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

    /// Ensures the on-device model assets for `locale` are installed AND allocated.
    ///
    /// Three distinct states to reconcile:
    ///   1. **Supported**  — a model *exists* for this locale (downloadable from Apple).
    ///   2. **Installed**  — the model bytes are already on disk.
    ///   3. **Reserved/Allocated** — this app has claimed an allocation slot for the
    ///      locale so the analyzer may actually load it. Missing this step is what
    ///      causes "Cannot use modules with unallocated locales", even when installed.
    private func ensureModelInstalled(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let targetID = locale.identifier(.bcp47)

        // ── 1. Is a model even available for this locale? ─────────────────────
        let supported = await SpeechTranscriber.supportedLocales
        let supportedIDs = supported.map { $0.identifier(.bcp47) }
        let isSupported = supportedIDs.contains(targetID)
        logger.info("[Assets] supportedLocales (\(supported.count)): \(supportedIDs.joined(separator: ", "))")
        if isSupported {
            logger.info("[Assets] ✅ A model IS AVAILABLE for \(targetID) (downloadable / on-device).")
        } else {
            logger.error("[Assets] ❌ NO MODEL AVAILABLE for \(targetID). This locale is not in supportedLocales.")
            throw TranscriptionError.localeNotSupported(targetID)
        }

        // ── 2. Is the model already installed on disk? ────────────────────────
        let installed = await SpeechTranscriber.installedLocales
        let installedIDs = installed.map { $0.identifier(.bcp47) }
        let isInstalled = installedIDs.contains(targetID)
        logger.info("[Assets] installedLocales (\(installed.count)): \(installedIDs.joined(separator: ", "))")
        logger.info("[Assets] Model on disk for \(targetID): \(isInstalled ? "YES" : "NO")")

        // ── 3. Download + install if not on disk ──────────────────────────────
        logger.info("[Assets] Requesting AssetInventory.assetInstallationRequest(supporting: [transcriber])…")
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                logger.info("[Assets] ⬇️ Downloading speech model for \(targetID)… (may be tens of MB on first use)")

                // Observe download progress.
                let progress = request.progress
                let observation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] prog, _ in
                    self?.logger.info("[Assets] Download progress for \(targetID): \(Int(prog.fractionCompleted * 100))%")
                }
                defer { observation.invalidate() }

                try await request.downloadAndInstall()
                logger.info("[Assets] ✅ downloadAndInstall() completed for \(targetID).")
            } else {
                logger.info("[Assets] No download required — model already installed for \(targetID).")
            }
        } catch {
            logger.error("[Assets] ❌ Download/install failed for \(targetID): \(error)")
            throw TranscriptionError.analyzerFailed(error)
        }

        // ── 4. Reserve (allocate) the locale — the step that fixes the warning ─
        let reservedBefore = await AssetInventory.reservedLocales
        logger.info("[Assets] reservedLocales BEFORE: \(reservedBefore.map { $0.identifier(.bcp47) }.joined(separator: ", "))")
        #if DEBUG
        // Probe outside the branch so we measure on every launch, including
        // when the locale was reserved by a previous run (Δ should be ≈ 0 then,
        // which is itself useful — confirms reserve doesn't re-allocate).
        let probeBefore = MemoryProbe.snapshot(label: "before reserve check (\(targetID))")
        #endif
        if reservedBefore.contains(where: { $0.identifier(.bcp47) == targetID }) {
            logger.info("[Assets] \(targetID) already reserved/allocated.")
        } else {
            logger.info("[Assets] Reserving (allocating) locale \(targetID) via AssetInventory.reserve(locale:)…")
            do {
                try await AssetInventory.reserve(locale: locale)
                logger.info("[Assets] ✅ Reserved \(targetID).")
            } catch {
                logger.error("[Assets] ⚠️ AssetInventory.reserve(locale:) failed for \(targetID): \(error)")
            }
        }
        #if DEBUG
        let probeAfter = MemoryProbe.snapshot(label: "after reserve check (\(targetID))")
        MemoryProbe.logDiff(before: probeBefore, after: probeAfter)
        #endif
        let reservedAfter = await AssetInventory.reservedLocales
        logger.info("[Assets] reservedLocales AFTER: \(reservedAfter.map { $0.identifier(.bcp47) }.joined(separator: ", "))")

        // ── 5. Report where the model lives on disk ───────────────────────────
        logModelStorageLocation(for: targetID)
    }

    /// Best-effort lookup + logging of where SpeechAnalyzer caches its model assets.
    ///
    /// Apple does not expose a public API for the exact asset path, so we probe the
    /// known on-device asset store locations and log what we find.
    private func logModelStorageLocation(for localeID: String) {
        let fm = FileManager.default
        let candidates: [URL] = [
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ].compactMap { $0 }

        var foundAny = false
        for base in candidates {
            let speechDirs = ["com.apple.speech", "SpeechAnalyzer", "Speech", "AssetInventory"]
            for sub in speechDirs {
                let path = base.appendingPathComponent(sub)
                if fm.fileExists(atPath: path.path) {
                    foundAny = true
                    logger.info("[Assets] 📁 Model/asset store found at: \(path.path)")
                }
            }
        }
        if !foundAny {
            logger.info("[Assets] ℹ️ Model assets are managed by the system asset store (no app-visible path). Locale \(localeID) is allocated and ready for on-device use.")
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
