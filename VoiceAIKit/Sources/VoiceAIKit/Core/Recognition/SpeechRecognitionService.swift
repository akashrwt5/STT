// SpeechRecognitionService.swift
// STT
//
// Single responsibility: SpeechAnalyzer + SpeechTranscriber lifecycle and result iteration.

@preconcurrency import AVFoundation
import Speech
import os.log

/// Callback interface for speech recognition events. Called on the main actor.
@MainActor
protocol SpeechRecognitionServiceDelegate: AnyObject {
    func recognitionService(_ service: SpeechRecognitionService, didReceivePartialResult result: TranscriptionResult)
    func recognitionService(_ service: SpeechRecognitionService, didReceiveFinalResult result: TranscriptionResult)
    func recognitionService(_ service: SpeechRecognitionService, didFailWith error: TranscriptionError)
    /// Called when the result stream completes normally (e.g. an input file is fully
    /// consumed). Not called when the session is cancelled or fails.
    func recognitionServiceDidComplete(_ service: SpeechRecognitionService)

    /// Called when the silence detector determines the session should end (the user
    /// stopped speaking, or never spoke). Only fired when silence detection is enabled.
    func recognitionServiceDidDetectSilence(_ service: SpeechRecognitionService)

    /// Called with the measured power (dBFS) of each fed audio buffer. Optional.
    func recognitionService(_ service: SpeechRecognitionService, didUpdateAudioLevel powerDBFS: Float)
}

extension SpeechRecognitionServiceDelegate {
    /// Default no-op so existing conformers need not implement level metering.
    func recognitionService(_ service: SpeechRecognitionService, didUpdateAudioLevel powerDBFS: Float) {}
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
final class SpeechRecognitionService {

    // MARK: - Public

    weak var delegate: SpeechRecognitionServiceDelegate?

    // MARK: - Private

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var currentLocale: Locale
    /// The single session task. The buffer feed loop, `analyzer.start`, and result
    /// iteration all run as children of one task group inside it, so cancelling this
    /// one handle tears the whole pipeline down together (structured concurrency —
    /// the feed can never outlive the session it belongs to).
    private var analysisTask: Task<Void, Never>?

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
    /// delegate callbacks (completion / failure) if its captured generation still
    /// matches — so a stale, slow-to-finish session can never fire a spurious
    /// completion or error for a session that has already replaced it.
    private var generation = 0
    /// Set once the transcriber commits its first final result. Read by the silence
    /// detector as a guardrail: end-of-speech silence only ends the session after a
    /// complete utterance, so a mid-sentence pause never cuts the user off.
    private var hasReceivedFinalResult = false
    /// Set once any (volatile or final) result contains non-empty text. The end-of-speech
    /// guardrail uses this instead of waiting for a *final* result: the transcriber
    /// commits finals on its own lazy cadence, so gating the VAD on a final creates a
    /// mutual wait (VAD waits for the final; nothing hurries the final along). "The user
    /// said something, then went silent for the timeout" is the correct condition.
    private var hasVolatileText = false
    /// Transcript-stability endpointing (primary). The last distinct partial text and
    /// when it changed. On this audio path (`.playAndRecord`, AGC active) speech and
    /// ambient noise sit within a few dB of each other, so energy-only VAD is
    /// unreliable — but "the decoder stopped producing new words" is noise-immune.
    /// When the partial hasn't changed for `speechEndTimeout`, the utterance is over.
    private var lastPartialText = ""
    private var lastPartialChangeAt: CFAbsoluteTime = 0
    /// Committed-segment accumulator for the live single-utterance path. Apple's
    /// `SpeechTranscriber` (`.progressiveTranscription`) finalizes a SEGMENT at each
    /// grammatical/pause boundary and immediately starts a fresh chunk, so a multi-clause
    /// sentence arrives as several finals whose subsequent volatile partials contain only
    /// the *new* chunk. We concatenate finalized segments here so the running transcript
    /// (finalized + current volatile) is always the WHOLE utterance. Reset per session.
    private var finalizedTranscript = ""
    /// Wall-clock time the user's first speech was detected this session (first non-empty
    /// transcript). `0` until then. Drives the `maxUtteranceDuration` safety cap.
    private var firstSpeechAt: CFAbsoluteTime = 0
    /// Set when the endpoint delivered the stable partial as the final result
    /// speculatively (before the recognizer's own final committed). The recognizer's
    /// real final, arriving ~50–100ms later during the drain, is then used only as a
    /// verification signal — logged if it disagrees — instead of being delivered
    /// again (which would double-trigger the NLU).
    private var didSynthesizeFinal = false
    /// Content-aware endpointing hook for the current session (see
    /// `TranscriptionCoordinator.endpointArbiter`). `nil` = fixed-window.
    private var endpointArbiter: (@MainActor (String) async -> SlotAnswerAssessment)?
    /// Arbitration cache: the arbiter runs regex/lexicon work on an actor, so its
    /// verdict is computed once per distinct stable text, not once per buffer.
    private var arbitratedText = ""
    private var arbitratedVerdict: SlotAnswerAssessment = .complete
    /// Locales whose model assets have been verified installed + reserved this app run.
    /// `ensureModelInstalled` makes ~6 async XPC round-trips — do them once per locale,
    /// not once per session/turn.
    private static var verifiedLocaleAssets = Set<String>()
    /// Memoizes `SpeechTranscriber.supportedLocale(equivalentTo:)` (an XPC call) per
    /// candidate identifier for the lifetime of the process.
    private static var localeResolutionCache: [String: Locale] = [:]
    private let logger = Logger(subsystem: "com.voiceaikit", category: "SpeechRecognitionService")

    // MARK: - Init

    init(locale: Locale) {
        self.currentLocale = locale
    }

    // MARK: - Pre-warm

    /// Kicks off the expensive one-time setup (locale resolution, model install/reserve,
    /// SpeechTranscriber + SpeechAnalyzer creation) in the background at launch so the
    /// first mic tap finds everything ready. Returns immediately; the work runs in a
    /// stored task that `startTranscribing` awaits.
    ///
    /// Idempotent — a second call while a prewarm is in flight (or already done) no-ops.
    func prewarm() {
        guard prewarmTask == nil else { return }
        prewarmTask = Task { [weak self] in await self?.performPrewarm() }
    }

    private func performPrewarm() async {
        #if DEBUG
        // Probe OFF the main actor: the VM-region walk takes hundreds of ms while
        // the process is actively allocating (the hang detector measured ~700ms).
        let probePrewarmStart = await Self.buildOffMain { MemoryProbe.snapshot(label: "prewarm START") }
        #endif

        // Prewarm for the locale this service was BUILT with (or last switched to) —
        // it is by definition the one the next session will use. This used to read
        // `UserDefaults["stt.userSelectedLocale"]` and run the auto-detect chain over
        // it, which meant the warmed model came from global state written by another
        // object rather than from `currentLocale` sitting right here.
        guard let resolvedLocale = try? await resolveTranscriberLocale(currentLocale) else {
            logger.warning("[Prewarm] Locale resolution failed — first tap will run full setup.")
            return
        }

        // Already warm for this locale? Nothing to do.
        if let cached = prewarmedLocale, cached.identifier(.bcp47) == resolvedLocale.identifier(.bcp47) {
            return
        }

        // Construct OFF the main actor: these initialisers synchronously map and
        // allocate the recognition model (~120+ MB per the MemoryProbe deltas).
        // This class is @MainActor, so without the hop that work blocked the main
        // thread — freezing the PVA sheet's presentation animation on first open.
        let t = await Self.buildOffMain { SpeechTranscriber(locale: resolvedLocale, preset: .progressiveTranscription) }
        do {
            try await ensureModelInstalled(for: t, locale: resolvedLocale)
        } catch {
            logger.error("[Prewarm] Model install failed: \(error) — first tap will retry.")
            return
        }

        // Bail if unload() cancelled us while the model was installing — storing the
        // pair now would resurrect state the caller explicitly released.
        guard !Task.isCancelled else {
            logger.info("[Prewarm] Cancelled — discarding prepared pair.")
            return
        }

        nonisolated(unsafe) let module = t
        let a = await Self.buildOffMain { SpeechAnalyzer(modules: [module]) }
        prewarmedTranscriber = t
        prewarmedAnalyzer    = a
        prewarmedLocale      = resolvedLocale
        logger.info("[Prewarm] ✅ SpeechTranscriber + SpeechAnalyzer ready for \(resolvedLocale.identifier(.bcp47)).")

        #if DEBUG
        nonisolated(unsafe) let startSnap = probePrewarmStart
        await Self.buildOffMain {
            let probePrewarmEnd = MemoryProbe.snapshot(label: "prewarm END")
            MemoryProbe.logDiff(before: startSnap, after: probePrewarmEnd)
        }
        #endif
    }

    // MARK: - Off-main construction

    /// Runs a synchronous, heavyweight constructor on a background queue and
    /// returns its result. `SpeechTranscriber`/`SpeechAnalyzer` initialisers map
    /// and allocate the recognition model synchronously — far too heavy for the
    /// main actor this class is isolated to. The value is freshly created inside
    /// the closure (region-disconnected), so `sending` it back is safe regardless
    /// of the SDK types' Sendable annotations.
    private nonisolated static func buildOffMain<T>(
        _ build: @escaping @Sendable () -> sending T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: build())
            }
        }
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
    func startTranscribing(
        from provider: any AudioInputProvider,
        preset: SpeechTranscriber.Preset = .progressiveTranscription,
        silenceConfiguration: SilenceDetectionConfiguration = .disabled,
        endpointArbiter: (@MainActor (String) async -> SlotAnswerAssessment)? = nil
    ) async throws {
        logger.info("━━━ startTranscribing called. Preset: \(String(describing: preset)), initial locale: \(self.currentLocale.identifier(.bcp47))")
        hasReceivedFinalResult = false
        hasVolatileText = false
        lastPartialText = ""
        lastPartialChangeAt = 0
        finalizedTranscript = ""
        firstSpeechAt = 0
        didSynthesizeFinal = false
        self.endpointArbiter = endpointArbiter
        arbitratedText = ""
        arbitratedVerdict = .complete
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
        // Prewarm always builds a `.progressiveTranscription` transcriber — only a live
        // session may consume it. Without this guard a file transcription (`.transcription`
        // preset) would silently steal the pair and run with the wrong preset.
        let prewarmCompatible = String(describing: preset)
            == String(describing: SpeechTranscriber.Preset.progressiveTranscription)
        if prewarmCompatible,
           let pw = prewarmedTranscriber,
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
            // The pair is consumed — clear the completed prewarm task so `prewarm()`
            // can re-arm for the *next* turn (see stopTranscribing). Previously this
            // stayed non-nil forever, so every turn after the first was a full cold
            // start: new transcriber, ~6 XPC asset checks, new analyzer (model load).
            prewarmTask = nil
        } else {
            logger.info("[1/6] Prewarm miss — running full setup for \(targetLocale.identifier(.bcp47)).")
            resolvedLocale = targetLocale
            // Same off-main construction as performPrewarm — these initialisers do
            // heavy synchronous model work that must not block the main thread.
            nonisolated(unsafe) let capturedPreset = preset
            let t = await Self.buildOffMain { SpeechTranscriber(locale: targetLocale, preset: capturedPreset) }
            logger.info("[3/6] Ensuring model assets are installed and allocated…")
            try await ensureModelInstalled(for: t, locale: resolvedLocale)
            logger.info("[3/6] Model asset check complete.")
            logger.info("[4/6] Creating SpeechAnalyzer…")
            nonisolated(unsafe) let module = t
            let a = await Self.buildOffMain { SpeechAnalyzer(modules: [module]) }
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

        // ── 5. Feed pipeline (raw buffers → AnalyzerInput) ────────────────────
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

        // The feed loop runs as a CHILD of the analysis task group below (not on this
        // class's @MainActor — group children don't inherit actor isolation), so
        // per-buffer format conversion + RMS never touch the main thread, and the
        // feed's lifetime is structurally tied to the session: cancelling
        // `analysisTask` cancels feed + analyzer + results together. The bindings are
        // `nonisolated(unsafe)` because AVAudio types aren't Sendable; each is created
        // above and used only inside the feed child.
        nonisolated(unsafe) let feedStream    = rawBufferStream
        nonisolated(unsafe) let feedConverter = converter
        nonisolated(unsafe) let feedVAD       = silenceDetector
        nonisolated(unsafe) let feedFormat    = analyzerFormat
        nonisolated(unsafe) let feedBuilder   = analyzerInputBuilder
        logger.info("[5/6] Feed pipeline prepared.")

        // ── 6. Session task (feed + analyzer + result consumption, one task tree) ──
        logger.info("[6/6] Starting session task…")
        let locale = currentLocale
        analysisTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            logger.info("[Analysis] Session task started. Entering withThrowingTaskGroup…")
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // Child 1 — feed loop: raw buffers → convert → AnalyzerInput.
                    // Runs off the main actor (children don't inherit isolation); the
                    // only main-actor contact is brief awaited hops for level reporting
                    // and the silence-stop check.
                    group.addTask { @Sendable [weak self] in
                        var bufferCount = 0
                        logger.debug("[Feed] Feed child started.")
                        for await buffer in feedStream {
                            guard !Task.isCancelled else {
                                logger.debug("[Feed] Feed child cancelled — breaking buffer loop.")
                                break
                            }
                            do {
                                let outputBuffer: AVAudioPCMBuffer
                                if let feedFormat {
                                    outputBuffer = try feedConverter.convert(buffer, to: feedFormat)
                                } else {
                                    outputBuffer = buffer
                                }

                                // The converter can hand back an empty buffer while priming or
                                // when it reports inputRanDry. Feeding one makes AVFoundation log
                                // a zero-byte-buffer warning, and it carries nothing for the RMS
                                // pass or the VAD.
                                guard outputBuffer.frameLength > 0 else {
                                    logger.debug("[Feed] Dropped empty buffer after #\(bufferCount).")
                                    continue
                                }

                                bufferCount += 1
                                feedBuilder.yield(AnalyzerInput(buffer: outputBuffer))

                                // One RMS pass per buffer, shared by the level meter and the VAD.
                                let power = outputBuffer.averagePowerDBFS()
                                await self?.reportAudioLevel(power)

                                // PRIMARY endpoint — transcript stability. The decoder emitting
                                // no new/changed partial for `speechEndTimeout` means the
                                // utterance is over, regardless of what the microphone energy
                                // says. This is the endpoint that actually fires under AGC,
                                // where ambient noise and speech overlap in level and the
                                // acoustic VAD below can starve (silence run keeps resetting).
                                // SAFETY CAP — max utterance duration. Once the user has
                                // been speaking for `maxUtteranceDuration`, force-commit even
                                // if the transcript is still changing, so a runaway / very
                                // long thinking pause always resolves.
                                if silenceConfiguration.isEnabled,
                                   await self?.shouldEndpointForMaxDuration(
                                       config: silenceConfiguration
                                   ) == true {
                                    await self?.commitStableTranscriptAsFinal()
                                    feedBuilder.finish()
                                    await self?.notifySilenceDetected()
                                    return
                                }

                                // PRIMARY endpoint — transcript stability (content-aware).
                                if silenceConfiguration.isEnabled,
                                   await self?.shouldEndpointForStableTranscript(
                                       config: silenceConfiguration
                                   ) == true {
                                    // Deliver the stable transcript as the final NOW —
                                    // NLU + TTS handoff overlap the analyzer drain.
                                    await self?.commitStableTranscriptAsFinal()
                                    feedBuilder.finish()
                                    await self?.notifySilenceDetected()
                                    return
                                }

                                // BACKSTOP endpoint — acoustic VAD, NO-SPEECH ONLY. The
                                // "spoke then trailed off" (endOfSpeech) case is owned solely
                                // by the content-aware stability endpoint above; letting the
                                // raw acoustic-silence timer also commit it would bypass the
                                // extended (freeform / incomplete) windows and cut the user off
                                // during a mid-thought pause in a quiet room. Here the VAD only
                                // handles "nobody ever spoke". `process()` still runs every
                                // buffer (adapting the noise floor) as part of the pattern match.
                                if let feedVAD,
                                   case .silenceDetected(let reason) = feedVAD.process(
                                       powerDBFS: power, frames: Int(outputBuffer.frameLength)
                                   ),
                                   reason == .noSpeech,
                                   await self?.shouldStopForSilence(.noSpeech) == true {
                                    logger.info("AK: [WHY-STOP] REASON=NO_SPEECH (nobody spoke within noSpeechTimeout=\(silenceConfiguration.noSpeechTimeout)s) → ending session, no NLU.")
                                    await self?.commitStableTranscriptAsFinal()
                                    feedBuilder.finish()
                                    await self?.notifySilenceDetected()
                                    return
                                }
                            } catch {
                                logger.error("[Feed] Buffer conversion failed at buffer #\(bufferCount): \(error)")
                            }
                        }
                        logger.debug("[Feed] Raw buffer stream exhausted. Total buffers fed: \(bufferCount). Finishing analyzer input stream.")
                        feedBuilder.finish()
                    }

                    // Child 2 — analyzer execution + finalization.
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

                    // Child 3 — result iteration. Runs on the MAIN ACTOR so delegate
                    // callbacks stay synchronous (delivery is identical to before), but as a
                    // task-group CHILD rather than the group body: if the analyzer child
                    // fails, the group observes that failure and cancels this loop instead of
                    // leaving it blocked forever on a results stream that will never close.
                    //
                    // `nonisolated(unsafe)`, the same idiom as the feed bindings above and
                    // for the same reason: `SpeechTranscriber` is not Sendable, this value is
                    // created in the enclosing scope and consumed by exactly one child. Without
                    // it, Swift 6's region-based isolation checker cannot analyse a `@MainActor`
                    // task-group child capturing a non-Sendable value from a nonisolated scope
                    // and reports "Pattern that the region-based isolation checker does not
                    // understand how to check" — a checker limitation, not an unsafe capture.
                    //
                    // Deliberately NOT `self.transcriber`, which would need no annotation at all
                    // inside this @MainActor closure: that property holds whatever transcriber is
                    // CURRENT, and a newer session may have replaced it (which is why this class
                    // carries a `generation` counter). This child must use the one its own
                    // session built.
                    nonisolated(unsafe) let resultsTranscriber = transcriber
                    // Child 3 is nonisolated like children 1 and 2; the main-actor hop
                    // happens inside `consumeResults`. See that method for why the isolation
                    // cannot live on this closure.
                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.consumeResults(from: resultsTranscriber,
                                                      locale: locale,
                                                      silenceConfiguration: silenceConfiguration)
                    }  // end Child 3 — result iteration

                    // Observe every child. The first to throw (e.g. analyzer.start failing)
                    // rethrows here; the throwing group then cancels the remaining children,
                    // and the error propagates to the outer catch → didFailWith — instead of
                    // the group body hanging on a results stream a failed analyzer never closes.
                    for try await _ in group { }
                }
                // Reached only on normal completion (input exhausted), not cancellation/error.
                // Guard with generation so a stale task can't fire completion for a session
                // that has already been replaced by a newer one.
                if !Task.isCancelled, self.generation == myGeneration {
                    self.delegate?.recognitionServiceDidComplete(self)
                }
            } catch {
                logger.error("[Analysis] Analysis task failed with error: \(error)")
                // Invalidate the per-run asset cache for this locale: a failure here can
                // mean the model was evicted since we verified it (user deleted speech
                // assets in Settings, or AssetInventory released the reservation when its
                // per-app limit was hit). The next session then re-runs the full
                // install/reserve check instead of failing for the rest of the run.
                Self.verifiedLocaleAssets.remove(locale.identifier(.bcp47))
                if self.generation == myGeneration {
                    self.delegate?.recognitionService(self, didFailWith: .analyzerFailed(error))
                }
            }
            // No cross-task cleanup needed: the feed loop is a child of the group
            // above, so it was cancelled with the group. (Previously the feed was an
            // independent task that had to be cancelled here behind a generation
            // check so a slow stale session couldn't kill a newer session's feed.)
            logger.info("[Analysis] Session task complete.")
        }
        logger.info("━━━ startTranscribing setup complete. Pipeline is running.")
    }

    /// Stops transcription and cancels in-flight tasks.
    ///
    /// `SpeechAnalyzer` has no explicit `stop()` — finishing the input stream and
    /// cancelling the tasks is the correct teardown.
    ///
    /// - Parameter rearmPrewarm: when `true` (default), immediately kicks off a fresh
    ///   prewarm so the *next* session finds a warm transcriber + analyzer. In the
    ///   conversation flow this overlaps the rebuild with the TTS prompt (~1–2s), so
    ///   the mic restart to capture the user's answer is near-instant instead of a
    ///   full cold start. `unload()` passes `false` — it wants everything released.
    func stopTranscribing(rearmPrewarm: Bool = true) async {
        logger.info("stopTranscribing called.")
        // One cancellation point: the feed loop, analyzer run, and result iteration
        // are all children of this task's group, so they cancel and drain together.
        analysisTask?.cancel()
        await analysisTask?.value
        analysisTask = nil
        analyzer = nil
        transcriber = nil
        logger.info("SpeechRecognitionService stopped.")
        if rearmPrewarm { prewarm() }
    }


    /// Child 3 of `startTranscribing`'s task group: iterate the transcriber's results and
    /// drive the delegate. Runs on the main actor (this class is `@MainActor`), so delegate
    /// delivery stays synchronous — exactly as it did when this was a closure.
    ///
    /// EXTRACTED FROM THE CLOSURE, and not for tidiness. Swift 6's region-based isolation
    /// checker cannot analyse a `@MainActor` closure passed to `TaskGroup.addTask` here:
    ///
    ///     Pattern that the region-based isolation checker does not understand how to check.
    ///     Please file a bug
    ///
    /// That is a checker limitation, not an unsafe capture — every value the body reaches for
    /// is either Sendable (`locale`, `silenceConfiguration`) or already opted out
    /// (`resultsTranscriber`). Neither `[weak self]` nor `[self]` avoids it; the trigger is
    /// the `@MainActor` closure itself. Moving the isolation from the CLOSURE to this METHOD
    /// gives the checker the shape it already handles — children 1 and 2 are nonisolated
    /// closures and compile fine.
    ///
    /// `resultsTranscriber` is passed rather than read from `self.transcriber`: that property
    /// holds whatever transcriber is CURRENT, and a newer session may have replaced it (hence
    /// this class's `generation` counter). This loop must use the one its own session built.
    private func consumeResults(
        from resultsTranscriber: SpeechTranscriber,
        locale: Locale,
        silenceConfiguration: SilenceDetectionConfiguration
    ) async throws {
        // `transcriber.results` is an async property in iOS 26.
        logger.info("[Results] Awaiting transcriber.results async property…")
        let resultStream = await resultsTranscriber.results
        logger.info("[Results] Got result stream. Starting iteration…")

        var resultCount = 0
        // Endpoint-lag instrumentation: time from the last transcript-changing
        // partial to the committed final. This is the "invisible" wait between
        // the user finishing their utterance and the pipeline being able to
        // respond — the span the VAD endpoint exists to bound.
        var lastPartialAt: CFAbsoluteTime?
        let latencyLog = Logger(subsystem: "com.voiceaikit", category: "Latency")
        for try await result in resultStream {
            guard !Task.isCancelled else {
                logger.info("[Results] Task cancelled — breaking result loop.")
                break
            }
            resultCount += 1
            let plainText = String(result.text.characters)
            let isFinal = result.isFinal
            logger.debug("AK: [Results] Result #\(resultCount): isFinal=\(isFinal), text='\(plainText)'")

            // ── Endpointing authority ─────────────────────────────────
            // Apple's SpeechTranscriber (.progressiveTranscription) emits
            // isFinal at each grammatical/pause boundary and then immediately
            // starts a NEW chunk. isFinal marks a stable SEGMENT, NOT the end of
            // the user's turn: "It's a bit louder here." finalizes mid-sentence
            // when the speaker pauses at the comma.
            //
            // On the live single-utterance path we treat every result (volatile
            // OR final) purely as transcript to accumulate, and let the feed-loop
            // endpointer be the SOLE authority on turn-end. Apple's isFinal never
            // triggers the NLU here. This is the fix for the premature-endpointing
            // bug (the mic no longer cuts off, and NLU no longer fires, mid-clause).
            if silenceConfiguration.isEnabled {
                // Turn already committed by the endpointer (speculative final /
                // VAD). Remaining results are analyzer-drain — never re-deliver.
                if self.hasReceivedFinalResult {
                    if isFinal {
                        self.appendFinalizedSegment(plainText)
                        if let lastPartialAt {
                            let lagMs = (CFAbsoluteTimeGetCurrent() - lastPartialAt) * 1000
                            latencyLog.info("ENDPOINT LAG: recognizer final committed \(lagMs, format: .fixed(precision: 0))ms after last partial (endpoint already fired).")
                        }
                    }
                    continue
                }

                // Commit finalized SEGMENTS into the accumulator; the running
                // transcript is (finalized segments + current volatile chunk),
                // so it is always the full utterance — not just the last chunk.
                if isFinal { self.appendFinalizedSegment(plainText) }
                let running = self.runningTranscript(withVolatile: isFinal ? "" : plainText)

                if !running.isEmpty {
                    if !self.hasVolatileText {
                        self.hasVolatileText = true
                        self.firstSpeechAt = CFAbsoluteTimeGetCurrent()
                    }
                    if running != self.lastPartialText {
                        self.lastPartialText = running
                        self.lastPartialChangeAt = CFAbsoluteTimeGetCurrent()
                    }
                }
                if !isFinal { lastPartialAt = CFAbsoluteTimeGetCurrent() }

                // Always surfaced as a PARTIAL — the turn's real final is
                // synthesized by commitStableTranscriptAsFinal() at endpoint.
                self.delegate?.recognitionService(
                    self,
                    didReceivePartialResult: TranscriptionResult(
                        text: running, isFinal: false, locale: locale, confidence: nil
                    )
                )
                continue
            }

            // ── File / continuous-captioning path (silence detection off) ──
            // No notion of a "turn": Apple's isFinal is authoritative and is
            // accumulated downstream (TranscriptionCoordinator / file loop).
            if !plainText.isEmpty {
                self.hasVolatileText = true
                if plainText != self.lastPartialText {
                    self.lastPartialText = plainText
                    self.lastPartialChangeAt = CFAbsoluteTimeGetCurrent()
                }
            }
            let transcriptionResult = TranscriptionResult(
                text: plainText, isFinal: isFinal, locale: locale, confidence: nil
            )
            if isFinal {
                self.hasReceivedFinalResult = true
                self.delegate?.recognitionService(self, didReceiveFinalResult: transcriptionResult)
            } else {
                lastPartialAt = CFAbsoluteTimeGetCurrent()
                self.delegate?.recognitionService(self, didReceivePartialResult: transcriptionResult)
            }
        }
        logger.info("[Results] Result stream exhausted. Total results received: \(resultCount).")
    }

    // MARK: - Feed-task helpers (main-actor hops from the detached feed loop)

    private func reportAudioLevel(_ powerDBFS: Float) {
        delegate?.recognitionService(self, didUpdateAudioLevel: powerDBFS)
    }

    private func shouldStopForSilence(_ reason: SilenceDetector.Outcome.Reason) -> Bool {
        EndpointDecider.shouldStop(
            for: reason,
            hasVolatileText: hasVolatileText,
            hasReceivedFinalResult: hasReceivedFinalResult
        )
    }

    /// Runaway guard — force-endpoint once the user has been speaking past
    /// `maxUtteranceDuration`. Word-boundary aware (never mid-word) with a hard-ceiling
    /// backstop. Delegates the math to `EndpointDecider`.
    private func shouldEndpointForMaxDuration(config: SilenceDetectionConfiguration) -> Bool {
        let fire = EndpointDecider(config: config).shouldEndpointForMaxDuration(
            now: CFAbsoluteTimeGetCurrent(),
            firstSpeechAt: firstSpeechAt,
            lastChangeAt: lastPartialChangeAt,
            hasVolatileText: hasVolatileText,
            hasReceivedFinalResult: hasReceivedFinalResult
        )
        if fire {
            let spokenFor = CFAbsoluteTimeGetCurrent() - firstSpeechAt
            logger.info("AK: [WHY-STOP] REASON=MAX_UTTERANCE_DURATION spokenFor=\(spokenFor, format: .fixed(precision: 2))s cap=\(config.maxUtteranceDuration)s → force-committing to NLU: '\(self.lastPartialText)'")
        }
        return fire
    }

    /// Commits a finalized SEGMENT into the running-utterance accumulator (live path).
    /// Apple hands back each segment once, then stops repeating it in later volatile
    /// results — so without stashing it here, the first clause is lost when the second
    /// starts streaming.
    private func appendFinalizedSegment(_ segment: String) {
        let s = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        finalizedTranscript = finalizedTranscript.isEmpty ? s : finalizedTranscript + " " + s
    }

    /// The full running transcript for the live path: all finalized segments joined with
    /// the current volatile chunk — always the complete utterance, never just the latest.
    private func runningTranscript(withVolatile volatile: String) -> String {
        let v = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalizedTranscript.isEmpty { return v }
        if v.isEmpty { return finalizedTranscript }
        return finalizedTranscript + " " + v
    }

    /// Primary endpoint check, evaluated per fed buffer: the utterance is over when
    /// the decoder has produced text and that text has stopped changing for the
    /// window. Two-tier when an arbiter is installed (content-aware endpointing):
    /// a COMPLETE answer commits at `speechEndTimeout`; an INCOMPLETE one (bare
    /// "tomorrow" for a date-time slot) waits `incompleteAnswerTimeout`, so a
    /// thinking pause mid-answer doesn't split one answer into two turns.
    private func shouldEndpointForStableTranscript(
        config: SilenceDetectionConfiguration
    ) async -> Bool {
        // Fast pre-check (also gates the arbiter): don't do content-aware work until at
        // least the base window has elapsed since the transcript last changed.
        guard hasVolatileText, !hasReceivedFinalResult, lastPartialChangeAt > 0 else { return false }
        guard CFAbsoluteTimeGetCurrent() - lastPartialChangeAt >= config.speechEndTimeout else { return false }

        // Resolve the content-aware verdict (cached per distinct stable text). No arbiter
        // → `.complete`, i.e. the base window, matching the prior fixed-window behaviour.
        var verdict: SlotAnswerAssessment = .complete
        if let endpointArbiter {
            if lastPartialText != arbitratedText {
                arbitratedText = lastPartialText
                arbitratedVerdict = await endpointArbiter(lastPartialText)
                switch arbitratedVerdict {
                case .complete:
                    break
                case .freeform:
                    logger.info("[Endpoint] '\(self.arbitratedText)' is FREEFORM — using medium window (\(config.freeformAnswerTimeout)s).")
                case .incomplete:
                    logger.info("[Endpoint] '\(self.arbitratedText)' judged INCOMPLETE — extending window to \(config.incompleteAnswerTimeout)s.")
                }
                // The arbiter suspended; the transcript may have moved on. Re-check the
                // base stability so we never commit a window that just restarted.
                guard hasVolatileText, !hasReceivedFinalResult,
                      CFAbsoluteTimeGetCurrent() - lastPartialChangeAt >= config.speechEndTimeout
                else { return false }
            }
            verdict = arbitratedVerdict
        }

        let now = CFAbsoluteTimeGetCurrent()
        let decider = EndpointDecider(config: config)
        let fire = decider.shouldEndpointForStableTranscript(
            now: now,
            lastChangeAt: lastPartialChangeAt,
            hasVolatileText: hasVolatileText,
            hasReceivedFinalResult: hasReceivedFinalResult,
            verdict: verdict,
            firstSpeechAt: firstSpeechAt
        )
        if fire {
            let spokenFor = firstSpeechAt > 0 ? now - firstSpeechAt : 0
            let requiredWindow = decider.requiredStabilityWindow(for: verdict, spokenFor: spokenFor)
            let stableFor = CFAbsoluteTimeGetCurrent() - lastPartialChangeAt
            logger.info("AK: [WHY-STOP] REASON=SILENCE_AFTER_SPEECH verdict=\(String(describing: verdict), privacy: .public) window=\(requiredWindow, format: .fixed(precision: 2))s stableFor=\(stableFor, format: .fixed(precision: 2))s spokenFor=\(spokenFor, format: .fixed(precision: 2))s → committing to NLU: '\(self.lastPartialText)'")
        }
        return fire
    }

    /// Speculative final ("do the homework early", à la Alexa's speculative endpointer):
    /// at endpoint time the stable partial *is* the transcript — deliver it as the final
    /// immediately so the NLU and TTS handoff start now, overlapping the analyzer drain
    /// instead of waiting ~50–100ms for the recognizer's own final to commit.
    private func commitStableTranscriptAsFinal() {
        guard !didSynthesizeFinal, !hasReceivedFinalResult, !lastPartialText.isEmpty else { return }
        didSynthesizeFinal = true
        hasReceivedFinalResult = true
        logger.info("AK: [WHY-STOP] COMMIT → final delivered to NLU: '\(self.lastPartialText)'")
        Logger(subsystem: "com.voiceaikit", category: "Latency")
            .info("SPECULATIVE FINAL: delivering stable transcript at endpoint (no finalize wait).")
        let result = TranscriptionResult(
            text: lastPartialText,
            isFinal: true,
            locale: currentLocale,
            confidence: nil
        )
        delegate?.recognitionService(self, didReceiveFinalResult: result)
    }

    /// Case/punctuation-insensitive comparison key for verifying the speculative final
    /// against the recognizer's committed one ("Tomorrow 5 PM" ≡ "Tomorrow, 5 PM").
    private static func transcriptKey(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private func notifySilenceDetected() {
        delegate?.recognitionServiceDidDetectSilence(self)
    }

    // MARK: - Manual Lifecycle (Diagnostic)

    /// Releases every speech-related ref held by this service. Pair with the
    /// MemoryProbe to verify whether the framework actually returns the dirty
    /// blocks to the OS when our handles drop.
    func unload() async {
        logger.info("[Unload] Releasing speech state…")
        await stopTranscribing(rearmPrewarm: false)
        // Cancel any in-flight prewarm so it can't repopulate the pair after we clear it.
        prewarmTask?.cancel()
        prewarmedTranscriber = nil
        prewarmedAnalyzer    = nil
        prewarmedLocale      = nil
        prewarmTask          = nil
        logger.info("[Unload] Done.")
    }

    /// Kicks off a prewarm (if not already running) and awaits its completion.
    /// Used by the diagnostic Load button so probes can wrap a complete cycle.
    func awaitPrewarm() async {
        prewarm()
        await prewarmTask?.value
    }

    /// Switches to a new locale for the next session.
    ///
    /// - Parameter identifier: BCP-47 locale identifier (e.g. "en-IN", "hi-IN").
    /// - Throws: `TranscriptionError.localeNotSupported` if no matching model exists.
    func switchLocale(to identifier: String) async throws {
        logger.info("switchLocale called with identifier: \(identifier)")
        let newLocale = try await resolveTranscriberLocale(Locale(identifier: identifier))
        currentLocale = newLocale
        logger.info("Locale switched to: \(newLocale.identifier(.bcp47))")

        // Invalidate a prewarmed pair built for the OLD locale and re-warm for the new
        // one. Without this, the stale pair + completed prewarm task blocked all future
        // re-warms, making every post-switch turn a full cold start.
        if prewarmedLocale?.identifier(.bcp47) != newLocale.identifier(.bcp47) {
            prewarmTask?.cancel()
            prewarmTask          = nil
            prewarmedTranscriber = nil
            prewarmedAnalyzer    = nil
            prewarmedLocale      = nil
            prewarm()
        }
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

        // ── 0. Already verified this app run? Skip the whole XPC dance. ───────
        // Install + reserve are sticky for the process lifetime; re-checking them
        // on every session added ~6 async round-trips per conversation turn.
        if Self.verifiedLocaleAssets.contains(targetID) {
            logger.debug("[Assets] \(targetID) already verified this run — skipping asset checks.")
            return
        }

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
        // Off the main actor: the region walk blocked main ~650ms here.
        let probeBefore = await Self.buildOffMain { MemoryProbe.snapshot(label: "before reserve check (\(targetID))") }
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
        nonisolated(unsafe) let beforeSnap = probeBefore
        await Self.buildOffMain {
            let probeAfter = MemoryProbe.snapshot(label: "after reserve check (\(targetID))")
            MemoryProbe.logDiff(before: beforeSnap, after: probeAfter)
        }
        #endif
        let reservedAfter = await AssetInventory.reservedLocales
        logger.info("[Assets] reservedLocales AFTER: \(reservedAfter.map { $0.identifier(.bcp47) }.joined(separator: ", "))")

        // ── 5. Report where the model lives on disk ───────────────────────────
        logModelStorageLocation(for: targetID)

        Self.verifiedLocaleAssets.insert(targetID)
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
        let candidateID = candidate.identifier(.bcp47)
        if let cached = Self.localeResolutionCache[candidateID] {
            return cached
        }
        logger.info("[Locale] Querying SpeechTranscriber.supportedLocale(equivalentTo: \(candidateID))…")
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
            logger.info("[Locale] Matched supported locale: \(match.identifier(.bcp47))")
            Self.localeResolutionCache[candidateID] = match
            return match
        }
        logger.error("[Locale] No supported locale found for: \(candidate.identifier(.bcp47))")
        throw TranscriptionError.localeNotSupported(candidate.identifier)
    }
}
