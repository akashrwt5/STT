// AudioCaptureService.swift
// STT
//
// Single responsibility: AVAudioEngine tap installation and live buffer streaming.

import AVFoundation
import Speech
import os.log

/// Captures live audio from the microphone (or connected hearing aid) and streams
/// `AnalyzerInput` buffers via `AsyncStream`.
///
/// Conforms to `AudioInputProvider` — the recognition service does not know this
/// is a live mic vs. any other audio source.
public final class AudioCaptureService: AudioInputProvider, @unchecked Sendable {

    // MARK: - AudioInputProvider

    public var audioFormat: AVAudioFormat {
        get async throws {
            try await resolveFormat()
        }
    }

    public private(set) var state: AudioInputState = .idle

    // MARK: - Private

    private let engine: AVAudioEngine
    private let logger = Logger(subsystem: "com.stt.module", category: "AudioCaptureService")
    private var streamContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private let bufferSize: AVAudioFrameCount = 4096
    private var accumulatedFrames: AVAudioFramePosition = 0
    private var resolvedFormat: AVAudioFormat?

    // MARK: - Init

    /// - Parameter engine: Injectable for testability. Defaults to a new `AVAudioEngine`.
    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    // MARK: - AudioInputProvider

    /// Starts the audio engine and installs a tap on the input node.
    ///
    /// - Returns: An `AsyncStream` that yields buffers until `stop()` is called.
    public func start() -> AsyncStream<AnalyzerInput> {
        accumulatedFrames = 0
        state = .preparing

        let stream = AsyncStream<AnalyzerInput> { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.streamContinuation = continuation
            // Tear down on stream cancellation — must dispatch to MainActor
            // because AVAudioEngine methods are @MainActor in iOS 26.
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.tearDownEngine() }
            }
            Task { [weak self] in
                await self?.startEngine(continuation: continuation)
            }
        }
        return stream
    }

    /// Stops the audio engine and finishes the buffer stream.
    public func stop() {
        streamContinuation?.finish()
        streamContinuation = nil
        state = .stopped
        // AVAudioEngine teardown must run on MainActor in iOS 26.
        Task { @MainActor [weak self] in self?.tearDownEngine() }
        logger.info("AudioCaptureService stopped.")
    }

    // MARK: - Private

    private func resolveFormat() async throws -> AVAudioFormat {
        if let cached = resolvedFormat { return cached }
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionError.unsupportedAudioFormat("Cannot create mono Float32 format")
        }
        resolvedFormat = format
        return format
    }

    private func startEngine(continuation: AsyncStream<AnalyzerInput>.Continuation) async {
        do {
            engine.inputNode.removeTap(onBus: 0)

            let format = try await resolveFormat()

            engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.accumulatedFrames += AVAudioFramePosition(buffer.frameLength)
                continuation.yield(buffer.analyzerInput())
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

    /// Must be called on `@MainActor` — AVAudioEngine's `stop()` and `removeTap` are
    /// main-actor-isolated in iOS 26.
    @MainActor
    private func tearDownEngine() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        logger.info("AVAudioEngine stopped.")
    }
}
