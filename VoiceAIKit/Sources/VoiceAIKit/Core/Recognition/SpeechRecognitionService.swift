// SpeechRecognitionService.swift
// VoiceAIKit
//
// Runs `SpeechAnalyzer` and `SpeechTranscriber` for one listening session. It feeds
// audio in, decides when the turn ends, and sends results to a delegate.

@preconcurrency import AVFoundation
import Speech
import os.log

/// Receives events from `SpeechRecognitionService`. All calls are on the main actor.
@MainActor
protocol SpeechRecognitionServiceDelegate: AnyObject {
    /// Called with the transcript so far.
    func recognitionService(_ service: SpeechRecognitionService, didReceivePartialResult result: TranscriptionResult)
    /// Called with the final transcript of the turn.
    func recognitionService(_ service: SpeechRecognitionService, didReceiveFinalResult result: TranscriptionResult)
    /// Called when recognition fails.
    func recognitionService(_ service: SpeechRecognitionService, didFailWith error: TranscriptionError)
    /// Called when the result stream ends normally (for example, when a file is fully
    /// read). Not called when the session is cancelled, fails, or is replaced by a newer one.
    func recognitionServiceDidComplete(_ service: SpeechRecognitionService)

    /// Called when the turn ended by the silence rules: the transcript stopped changing,
    /// `maxUtteranceDuration` was reached, or nobody spoke. Only called when silence
    /// detection is on.
    func recognitionServiceDidDetectSilence(_ service: SpeechRecognitionService)

    /// Called with the level (dBFS) of each audio buffer that is fed to the recognizer.
    func recognitionService(_ service: SpeechRecognitionService, didUpdateAudioLevel powerDBFS: Float)
}

extension SpeechRecognitionServiceDelegate {
    /// Does nothing by default, so a delegate does not have to implement level updates.
    func recognitionService(_ service: SpeechRecognitionService, didUpdateAudioLevel powerDBFS: Float) {}
}

/// Runs speech recognition for one session at a time.
///
/// It takes audio from any `AudioInputProvider`, converts each buffer to the format
/// `SpeechAnalyzer` needs, feeds it in, and sends results to the delegate.
///
/// Two modes:
///   - Silence detection on (live turns): every recognizer result is sent as a partial
///     result. The service ends the turn itself and sends one final result.
///   - Silence detection off (files, continuous captioning): the recognizer's own
///     results are passed on, and its final results are marked final.
///
/// `@MainActor`. Audio conversion, the analyzer and result reading run in child tasks,
/// so the main thread is not blocked.
@MainActor
final class SpeechRecognitionService {

    // MARK: - Public

    weak var delegate: SpeechRecognitionServiceDelegate?

    // MARK: - Private

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var currentLocale: Locale
    /// The task of the current session. The feed loop, `analyzer.start` and result reading
    /// are its child tasks, so cancelling it stops all three.
    private var analysisTask: Task<Void, Never>?

    /// The transcriber and analyzer prepared by `prewarm()`. The next `startTranscribing`
    /// uses and clears them if the locale matches and the preset is `.progressiveTranscription`.
    private var prewarmedTranscriber: SpeechTranscriber?
    private var prewarmedAnalyzer: SpeechAnalyzer?
    private var prewarmedLocale: Locale?
    /// The running or finished prewarm. `startTranscribing` waits for it, so two model
    /// installs for the same locale do not start at the same time.
    private var prewarmTask: Task<Void, Never>?
    /// Increases with every `startTranscribing`. A finishing task calls the delegate only if
    /// its generation is still current, so an old session cannot send a completion or an
    /// error for a newer one.
    private var generation = 0
    /// True once a final result has been delivered to the delegate. In live mode, later
    /// recognizer results are then ignored.
    private var hasReceivedFinalResult = false
    /// True once any result has non-empty text (partial or final).
    private var hasVolatileText = false
    /// The latest transcript and when it last changed. The end-of-turn check ends the turn
    /// when the transcript stays unchanged long enough (see `EndpointDecider`). It does not
    /// depend on the microphone level.
    private var lastPartialText = ""
    private var lastPartialChangeAt: CFAbsoluteTime = 0
    /// The finalized segments of this turn, joined. The recognizer finalizes a segment at
    /// each pause and then sends only the new chunk. So the full transcript is these
    /// segments plus the current partial. Reset for every session.
    private var finalizedTranscript = ""
    /// When the first non-empty transcript arrived in this session. `0` until then. Used
    /// for `maxUtteranceDuration` and the adaptive wait.
    private var firstSpeechAt: CFAbsoluteTime = 0
    /// True when the service delivered the final result itself at the end of the turn,
    /// before the recognizer's own final. The recognizer's later final is not delivered
    /// again, because that would run the NLU twice.
    private var didSynthesizeFinal = false
    /// Decides how long to wait, from the current text (see
    /// `TranscriptionCoordinator.endpointArbiter`). `nil` means the answer is always `.complete`.
    private var endpointArbiter: (@MainActor (String) async -> SlotAnswerAssessment)?
    /// The last text given to the arbiter and its verdict. The arbiter runs once for each
    /// different text, not once for each buffer.
    private var arbitratedText = ""
    private var arbitratedVerdict: SlotAnswerAssessment = .complete
    /// Locales whose model is installed and reserved in this run. `ensureModelInstalled`
    /// skips them.
    private static var verifiedLocaleAssets = Set<String>()
    /// Results of `supportedLocale(equivalentTo:)`, by locale identifier, for this run.
    private static var localeResolutionCache: [String: Locale] = [:]
    private let logger = Logger(subsystem: "com.voiceaikit", category: "SpeechRecognitionService")

    // MARK: - Init

    /// - Parameter locale: The locale for the sessions. Change it with `switchLocale(to:)`.
    init(locale: Locale) {
        self.currentLocale = locale
    }

    // MARK: - Pre-warm

    /// Starts the slow setup in the background: finds the locale, installs and reserves the
    /// model, and creates the transcriber and analyzer. The next `startTranscribing` then
    /// starts faster. It returns at once. It does nothing if a prewarm is running or done.
    func prewarm() {
        guard prewarmTask == nil else { return }
        prewarmTask = Task { [weak self] in await self?.performPrewarm() }
    }

    private func performPrewarm() async {
        #if DEBUG
        // Measure off the main actor: the memory snapshot is slow.
        let probePrewarmStart = await Self.buildOffMain { MemoryProbe.snapshot(label: "prewarm START") }
        #endif

        // Prewarm for `currentLocale`, which is the locale the next session will use.
        guard let resolvedLocale = try? await resolveTranscriberLocale(currentLocale) else {
            logger.warning("[Prewarm] Locale resolution failed — first tap will run full setup.")
            return
        }

        // Already warm for this locale? Nothing to do.
        if let cached = prewarmedLocale, cached.identifier(.bcp47) == resolvedLocale.identifier(.bcp47) {
            return
        }

        // Create these off the main actor. The initialisers load the recognition model
        // synchronously, which would block the main thread.
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

    /// Runs a heavy synchronous constructor on a background queue and returns the result.
    /// The `SpeechTranscriber` and `SpeechAnalyzer` initialisers load the model
    /// synchronously, which is too slow for the main actor. The value is created inside the
    /// closure, so it can be returned with `sending`.
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

    /// Starts transcribing audio from `provider`. It returns when the pipeline is set up.
    /// Audio processing continues in the background, and results go to the delegate.
    ///
    /// - Parameters:
    ///   - provider: The audio source (microphone, host app or file).
    ///   - preset: `.progressiveTranscription` for live audio, `.transcription` for files.
    ///   - silenceConfiguration: When enabled, the service ends the turn by the silence rules.
    ///     Defaults to `.disabled` (manual stop only).
    ///   - endpointArbiter: Optional. Decides how long to wait, from the current text.
    /// - Throws: `TranscriptionError.localeNotSupported` if the locale has no model, and
    ///   `TranscriptionError.analyzerFailed` if the model cannot be installed. Errors after
    ///   the start go to the delegate.
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

        // ── 1-4. Locale, model install, transcriber and analyzer ──
        // Use the prewarmed pair if it matches the requested locale. If there is none, or the
        // locale changed, run the full setup.
        let resolvedLocale: Locale
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer

        // Wait for a running prewarm, so its transcriber and analyzer are reused and no second
        // model install starts for the same locale. If there is none, this returns at once.
        await prewarmTask?.value

        let targetLocale = try await resolveTranscriberLocale(currentLocale)
        // Prewarm builds a `.progressiveTranscription` transcriber, so only a live session may
        // use it. Otherwise a file session (`.transcription`) would take it and run with the
        // wrong preset.
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
            // The pair is used, so clear the finished prewarm task. Then `prewarm()` can start
            // again for the next turn (see `stopTranscribing`).
            prewarmTask = nil
        } else {
            logger.info("[1/6] Prewarm miss — running full setup for \(targetLocale.identifier(.bcp47)).")
            resolvedLocale = targetLocale
            // Build off the main actor, as in `performPrewarm`. The initialisers load the model
            // synchronously.
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

        // Measures the loudness of each buffer to detect "no speech". The sample rate comes
        // from the analyzer format the buffers are converted to (default 16 kHz).
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

        // The feed loop runs as a child of the task group below, not on the main actor (group
        // children do not inherit actor isolation). So the conversion and loudness measurement
        // of each buffer stay off the main thread, and cancelling `analysisTask` cancels the
        // feed too. The bindings are `nonisolated(unsafe)` because AVAudio types are not
        // Sendable. Each one is created above and used only inside the feed child.
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
                    // Child 1 — feed loop: raw buffers, convert, send to the analyzer. It runs off the
                    // main actor. It goes to the main actor only for short awaited calls (level
                    // reporting and the end-of-turn checks).
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

                                // Upper limit on the turn. After `maxUtteranceDuration`, end the turn (see
                                // `EndpointDecider.shouldEndpointForMaxDuration`).
                                if silenceConfiguration.isEnabled,
                                   await self?.shouldEndpointForMaxDuration(
                                       config: silenceConfiguration
                                   ) == true {
                                    await self?.commitStableTranscriptAsFinal()
                                    feedBuilder.finish()
                                    await self?.notifySilenceDetected()
                                    return
                                }

                                // Main end-of-turn check. The turn ends when the transcript has not changed for the
                                // required time, whatever the microphone level is.
                                if silenceConfiguration.isEnabled,
                                   await self?.shouldEndpointForStableTranscript(
                                       config: silenceConfiguration
                                   ) == true {
                                    // Send the transcript as the final result now. The NLU and TTS start while the
                                    // analyzer is still finishing.
                                    await self?.commitStableTranscriptAsFinal()
                                    feedBuilder.finish()
                                    await self?.notifySilenceDetected()
                                    return
                                }

                                // No-speech check only. `SilenceDetector.process` runs on every buffer to keep its
                                // noise level up to date, but only its `.noSpeech` result is used. The end-of-turn
                                // check decides when the user has finished, so a pause during an answer is not cut
                                // short.
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

                        // Finish the analyzer. Starting it and reaching the end of the input does not flush
                        // pending audio or close `transcriber.results`, so without this the results loop
                        // waits forever. `finalizeAndFinishThroughEndOfInput()` turns the buffered audio into
                        // final results and then closes the results stream. This works for files (the input
                        // ends when the file is read) and for live audio (the input ends when the buffer
                        // stream finishes).
                        logger.info("[Analyzer] Finalizing analyzer through end of input…")
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                        logger.info("[Analyzer] finalizeAndFinishThroughEndOfInput() returned.")
                    }

                    // Child 3 — reads the results. It uses this session's transcriber, not
                    // `self.transcriber`, which a newer session may have replaced.
                    // `nonisolated(unsafe)`: `SpeechTranscriber` is not Sendable, and only this child uses it.
                    nonisolated(unsafe) let resultsTranscriber = transcriber
                    // The main-actor work is inside `consumeResults`. It is a method because Swift 6's
                    // isolation checker cannot check a main-actor closure here.
                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.consumeResults(from: resultsTranscriber,
                                                      locale: locale,
                                                      silenceConfiguration: silenceConfiguration)
                    }  // end Child 3 — result iteration

                    // Wait for every child. If one throws (for example `analyzer.start`), the group
                    // cancels the others and the error goes to the `catch` below, which calls `didFailWith`.
                    for try await _ in group { }
                }
                // Reached only when the input ended normally, not on cancel or error. The generation
                // check stops an old session from reporting completion for a newer one.
                if !Task.isCancelled, self.generation == myGeneration {
                    self.delegate?.recognitionServiceDidComplete(self)
                }
            } catch {
                logger.error("[Analysis] Analysis task failed with error: \(error)")
                // Forget the verified state of this locale. The model may have been removed (for
                // example the user deleted the speech assets, or the system released the
                // reservation). The next session then checks and installs it again.
                Self.verifiedLocaleAssets.remove(locale.identifier(.bcp47))
                if self.generation == myGeneration {
                    self.delegate?.recognitionService(self, didFailWith: .analyzerFailed(error))
                }
            }
            // Nothing else to clean up: the feed loop is a child of the group, so it was
            // cancelled with it.
            logger.info("[Analysis] Session task complete.")
        }
        logger.info("━━━ startTranscribing setup complete. Pipeline is running.")
    }

    /// Stops transcription and cancels the running tasks. `SpeechAnalyzer` has no `stop()`.
    /// Finishing the input and cancelling the tasks is how it is stopped.
    ///
    /// - Parameter rearmPrewarm: When `true` (default), starts a new prewarm so the next
    ///   session starts faster. `unload()` passes `false`.
    func stopTranscribing(rearmPrewarm: Bool = true) async {
        logger.info("stopTranscribing called.")
        // One cancel: the feed loop, the analyzer and the result reading are children of this
        // task and stop together.
        analysisTask?.cancel()
        await analysisTask?.value
        analysisTask = nil
        analyzer = nil
        transcriber = nil
        logger.info("SpeechRecognitionService stopped.")
        if rearmPrewarm { prewarm() }
    }


    /// Child 3 of `startTranscribing`'s task group: reads the transcriber's results and
    /// calls the delegate. It runs on the main actor.
    ///
    /// It is a method, not a closure, because Swift 6's isolation checker cannot check a
    /// main-actor closure passed to `addTask` here. `resultsTranscriber` is passed in, not
    /// read from `self.transcriber`, so it is the one this session built.
    private func consumeResults(
        from resultsTranscriber: SpeechTranscriber,
        locale: Locale,
        silenceConfiguration: SilenceDetectionConfiguration
    ) async throws {
        logger.info("[Results] Awaiting transcriber.results async property…")
        let resultStream = await resultsTranscriber.results
        logger.info("[Results] Got result stream. Starting iteration…")

        var resultCount = 0
        // Used to log the delay between the last partial result and the final one.
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

            // ── Live mode (silence detection on) ──────────────────────
            // `isFinal` marks a segment, not the end of the turn: the recognizer can finalize at a
            // comma, for example. So every result is added to the running transcript and sent as
            // a partial. The final result is sent by `commitStableTranscriptAsFinal()` when the
            // end-of-turn rules fire.
            if silenceConfiguration.isEnabled {
                // The turn is already committed by the end-of-turn rules. The remaining results
                // arrive while the analyzer finishes. Do not deliver them again.
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

                // Add finalized segments to `finalizedTranscript`. The running transcript is the
                // finalized segments plus the current partial, so it is always the whole utterance.
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

                // Always sent as a partial. The final result is sent by
                // `commitStableTranscriptAsFinal()` at the end of the turn.
                self.delegate?.recognitionService(
                    self,
                    didReceivePartialResult: TranscriptionResult(
                        text: running, isFinal: false, locale: locale, confidence: nil
                    )
                )
                continue
            }

            // ── Silence detection off (files, continuous captioning) ──
            // There are no turns. The recognizer's `isFinal` is passed on.
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

    /// Sends the level of one buffer to the delegate.
    private func reportAudioLevel(_ powerDBFS: Float) {
        delegate?.recognitionService(self, didUpdateAudioLevel: powerDBFS)
    }

    /// Whether a result of the audio check should end the turn (see `EndpointDecider.shouldStop`).
    private func shouldStopForSilence(_ reason: SilenceDetector.Outcome.Reason) -> Bool {
        EndpointDecider.shouldStop(
            for: reason,
            hasVolatileText: hasVolatileText,
            hasReceivedFinalResult: hasReceivedFinalResult
        )
    }

    /// Upper limit on the turn: true once the user has been speaking for longer than
    /// `maxUtteranceDuration`. The rules are in `EndpointDecider`.
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

    /// Main end-of-turn check, run for each fed buffer: true when the decoder has produced
    /// text and the text has not changed for the required window.
    ///
    /// When an arbiter is set, the window depends on the answer. A complete answer waits
    /// `speechEndTimeout`. An unfinished one (for example "tomorrow" when a time is needed)
    /// waits `incompleteAnswerTimeout`, so a pause in the middle of an answer does not split
    /// it into two turns.
    private func shouldEndpointForStableTranscript(
        config: SilenceDetectionConfiguration
    ) async -> Bool {
        // Quick check first: the arbiter is not called until the base window has passed since
        // the transcript last changed.
        guard hasVolatileText, !hasReceivedFinalResult, lastPartialChangeAt > 0 else { return false }
        guard CFAbsoluteTimeGetCurrent() - lastPartialChangeAt >= config.speechEndTimeout else { return false }

        // Get the verdict from the arbiter (once for each different text). With no arbiter,
        // it is `.complete`, so the base window is used.
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

    /// Sends the current transcript as the final result now, without waiting for the
    /// recognizer's own final. The NLU and TTS then start earlier.
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

    /// A key that ignores case and punctuation ("Tomorrow 5 PM" and "Tomorrow, 5 PM" match).
    /// Currently not used.
    private static func transcriptKey(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// Tells the delegate that the turn ended by the silence rules.
    private func notifySilenceDetected() {
        delegate?.recognitionServiceDidDetectSilence(self)
    }

    // MARK: - Lifecycle

    /// Stops the session and releases the transcriber, the analyzer and any prewarmed pair.
    /// It also cancels a running prewarm.
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

    /// Starts a prewarm if none is running, and waits until it finishes.
    func awaitPrewarm() async {
        prewarm()
        await prewarmTask?.value
    }

    /// Sets the locale for the next session.
    ///
    /// - Parameter identifier: BCP-47 locale identifier (for example "en-IN", "hi-IN").
    /// - Throws: `TranscriptionError.localeNotSupported` if no matching model exists.
    func switchLocale(to identifier: String) async throws {
        logger.info("switchLocale called with identifier: \(identifier)")
        let newLocale = try await resolveTranscriberLocale(Locale(identifier: identifier))
        currentLocale = newLocale
        logger.info("Locale switched to: \(newLocale.identifier(.bcp47))")

        // A prewarmed pair for the old locale cannot be used. Drop it and prewarm the new
        // locale.
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

    /// Makes sure the on-device model for `locale` is installed and reserved.
    ///
    /// Three states:
    ///   1. **Supported**: a model exists for this locale (it can be downloaded).
    ///   2. **Installed**: the model files are already on the device.
    ///   3. **Reserved**: this app has claimed an allocation for the locale, so the
    ///      analyzer can load it.
    private func ensureModelInstalled(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let targetID = locale.identifier(.bcp47)

        // ── 0. Already checked in this run? ───────────────────────
        // Install and reserve stay valid for the whole run, so each locale is checked once.
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

        // ── 4. Reserve the locale ─────────────────────────────────
        let reservedBefore = await AssetInventory.reservedLocales
        logger.info("[Assets] reservedLocales BEFORE: \(reservedBefore.map { $0.identifier(.bcp47) }.joined(separator: ", "))")
        #if DEBUG
        // Measure in every run, including when the locale was already reserved. Off the main
        // actor, because the memory snapshot is slow.
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

    /// Logs where the speech model files may be stored. It only checks a few known
    /// folders, so it can find nothing.
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

    /// Finds the supported locale that matches `candidate`. The result is cached.
    /// - Throws: `TranscriptionError.localeNotSupported` if there is no match.
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
