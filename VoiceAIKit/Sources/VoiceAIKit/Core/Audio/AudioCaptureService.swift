// AudioCaptureService.swift
// STT
//
// Single responsibility: AVAudioEngine tap installation and live buffer streaming.

@preconcurrency import AVFoundation
import os
import os.log

/// Captures live audio from the microphone (or connected hearing aid) and streams
/// raw `AVAudioPCMBuffer`s via `AsyncStream`.
///
/// Conforms to `AudioInputProvider` — the recognition service does not know this
/// is a live mic vs. any other audio source, and is responsible for converting the
/// buffers to the analyzer's required format.
final class AudioCaptureService: AudioInputProvider, @unchecked Sendable {

    // MARK: - AudioInputProvider

    var audioFormat: AVAudioFormat {
        get async throws { await resolveFormat() }
    }

    private(set) var state: AudioInputState = .idle

    // MARK: - Private

    private let engine: AVAudioEngine
    private let logger = Logger(subsystem: "com.voiceaikit", category: "AudioCaptureService")
    /// Lock-protected so `start()` (AsyncStream closure) and `stop()` can safely
    /// read/write the continuation from any calling context without a data race.
    /// In practice both are called from @MainActor, but this is not compiler-enforced.
    private let continuationLock = OSAllocatedUnfairLock<
        AsyncStream<AVAudioPCMBuffer>.Continuation?
    >(initialState: nil)
    private let bufferSize: AVAudioFrameCount = 4096
    /// Set the instant `stop()` is called. The tap closure checks it so a not-yet-torn-down
    /// engine can't keep yielding buffers after stop (the actual `engine.stop()` runs on a
    /// later main-actor hop). Prevents stale buffers leaking into a new session's pipeline.
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    // MARK: - Init

    /// - Parameter engine: Injectable for testability. Defaults to a new `AVAudioEngine`.
    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    // MARK: - AudioInputProvider

    /// Starts the audio engine and installs a tap on the input node.
    ///
    /// - Returns: An `AsyncStream` of raw buffers (in the input node's native format)
    ///   that yields until `stop()` is called.
    func start() -> AsyncStream<AVAudioPCMBuffer> {
        state = .preparing
        stopped.withLock { $0 = false }
        return AsyncStream<AVAudioPCMBuffer> { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            continuationLock.withLock { $0 = continuation }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.tearDownEngine() }
            }
            Task { @MainActor [weak self] in
                self?.startEngine(continuation: continuation)
            }
        }
    }

    /// Stops the audio engine and finishes the buffer stream.
    func stop() {
        stopped.withLock { $0 = true }
        continuationLock.withLock {
            $0?.finish()
            $0 = nil
        }
        state = .stopped
        Task { @MainActor [weak self] in self?.tearDownEngine() }
        logger.info("AudioCaptureService stopped.")
    }

    // MARK: - Private

    @MainActor
    private func resolveFormat() -> AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    @MainActor
    private func startEngine(continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) {
        do {
            engine.inputNode.removeTap(onBus: 0)

            // Tap in the input node's NATIVE format. Forcing a format on the tap can
            // fail when it doesn't match the hardware; conversion to the analyzer's
            // required format happens later in SpeechRecognitionService.
            let format = resolveFormat()

            engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [stopped] buffer, _ in
                // Drop buffers the instant stop() is called, even though the engine's own
                // teardown happens on a later main-actor hop — prevents stale buffers from
                // a stopping session leaking into a freshly started one.
                guard !stopped.withLock({ $0 }) else { return }
                // The tap buffer is only valid for the duration of this callback; the
                // engine may reuse its storage afterwards. Deep-copy before yielding it
                // to the async stream, which is consumed on another task later.
                guard let copy = buffer.deepCopy() else { return }
                continuation.yield(copy)
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
