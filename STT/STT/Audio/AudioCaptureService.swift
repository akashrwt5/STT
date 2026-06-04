// AudioCaptureService.swift
// STT
//
// Single responsibility: AVAudioEngine tap installation and live buffer streaming.

import AVFoundation
import os.log

/// Captures live audio from the microphone (or connected hearing aid) and streams
/// raw `AVAudioPCMBuffer`s via `AsyncStream`.
///
/// Conforms to `AudioInputProvider` — the recognition service does not know this
/// is a live mic vs. any other audio source, and is responsible for converting the
/// buffers to the analyzer's required format.
public final class AudioCaptureService: AudioInputProvider, @unchecked Sendable {

    // MARK: - AudioInputProvider

    public var audioFormat: AVAudioFormat {
        get async throws { await resolveFormat() }
    }

    public private(set) var state: AudioInputState = .idle

    // MARK: - Private

    private let engine: AVAudioEngine
    private let logger = Logger(subsystem: "com.stt.module", category: "AudioCaptureService")
    private var streamContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private let bufferSize: AVAudioFrameCount = 4096

    // MARK: - Init

    /// - Parameter engine: Injectable for testability. Defaults to a new `AVAudioEngine`.
    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    // MARK: - AudioInputProvider

    /// Starts the audio engine and installs a tap on the input node.
    ///
    /// - Returns: An `AsyncStream` of raw buffers (in the input node's native format)
    ///   that yields until `stop()` is called.
    public func start() -> AsyncStream<AVAudioPCMBuffer> {
        state = .preparing
        return AsyncStream<AVAudioPCMBuffer> { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.streamContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.tearDownEngine() }
            }
            Task { [weak self] in
                await self?.startEngine(continuation: continuation)
            }
        }
    }

    /// Stops the audio engine and finishes the buffer stream.
    public func stop() {
        streamContinuation?.finish()
        streamContinuation = nil
        state = .stopped
        Task { @MainActor [weak self] in self?.tearDownEngine() }
        logger.info("AudioCaptureService stopped.")
    }

    // MARK: - Private

    @MainActor
    private func resolveFormat() -> AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    private func startEngine(continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) async {
        do {
            engine.inputNode.removeTap(onBus: 0)

            // Tap in the input node's NATIVE format. Forcing a format on the tap can
            // fail when it doesn't match the hardware; conversion to the analyzer's
            // required format happens later in SpeechRecognitionService.
            let format = await resolveFormat()

            engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
                continuation.yield(buffer)
            }

            engine.prepare()
            try engine.start()
            state = .active
            logger.info("AudioCaptureService started. Sample rate: \(format.sampleRate) Hz")
        } catch {
            logger.error("AudioCaptureService failed to start: \(error)")
            state = .failed(error)
            continuation.finish()
        }
    }

    /// Must run on `@MainActor` — `AVAudioEngine.stop()`/`removeTap` are main-actor-isolated in iOS 26.
    @MainActor
    private func tearDownEngine() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        logger.info("AVAudioEngine stopped.")
    }
}
