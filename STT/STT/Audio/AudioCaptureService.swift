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
            continuation.onTermination = { [weak self] _ in
                self?.tearDownEngine()
            }
            Task { [weak self] in
                await self?.startEngine(continuation: continuation)
            }
        }
        return stream
    }

    /// Stops the audio engine and finishes the buffer stream.
    public func stop() {
        state = .stopping
        tearDownEngine()
        streamContinuation?.finish()
        streamContinuation = nil
        state = .stopped
        logger.info("AudioCaptureService stopped.")
    }

    // MARK: - Private

    private func resolveFormat() async throws -> AVAudioFormat {
        if let cached = resolvedFormat { return cached }

        // Use SpeechAnalyzer's preferred format for the current locale configuration.
        // Falls back to the input node's native format if the API is unavailable.
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
            // Must remove any existing tap before installing a new one.
            engine.inputNode.removeTap(onBus: 0)

            let format = try await resolveFormat()
            let sampleRate = format.sampleRate

            engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                let startTime = Double(self.accumulatedFrames) / sampleRate
                self.accumulatedFrames += AVAudioFramePosition(buffer.frameLength)
                let input = buffer.analyzerInput(bufferStartTime: startTime)
                continuation.yield(input)
            }

            engine.prepare()
            try engine.start()
            state = .active
            logger.info("AudioCaptureService started. Sample rate: \(sampleRate) Hz")
        } catch {
            logger.error("AudioCaptureService failed to start: \(error)")
            state = .failed(error)
            continuation.finish()
        }
    }

    private func tearDownEngine() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        logger.info("AVAudioEngine stopped.")
    }
}
