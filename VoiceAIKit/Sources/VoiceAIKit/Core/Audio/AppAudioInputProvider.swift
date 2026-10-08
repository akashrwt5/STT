// AppAudioInputProvider.swift
// VoiceAIKit
//
// An `AudioInputProvider` for host apps that own the microphone and audio session.
// The host pushes raw PCM into it with `enqueue(_:)`.

@preconcurrency import AVFoundation
import os
import os.log

/// An `AudioInputProvider` that receives audio from the host app, instead of the
/// package opening the microphone.
///
/// It is used when a session is created with `audioSource == .appProvided`. The host
/// owns the `AVAudioSession`, the microphone, permissions and interruptions. It calls
/// `enqueue(_:)` with chunks of raw PCM as they arrive.
///
/// Audio format: **Int16, mono, interleaved**, at the sample rate passed to `init`.
/// `SpeechRecognitionService` converts the buffers to the format `SpeechAnalyzer`
/// needs.
///
/// `SpeechRecognitionService` calls `start()` when a turn opens, and
/// `TranscriptionCoordinator` calls `stop()` when the turn ends. Audio pushed while no
/// turn is active is dropped, so audio from one turn does not appear in the next.
///
/// `@unchecked Sendable`: `state` changes only in `start()` and `stop()`, which are
/// called from `@MainActor` code. `enqueue(_:)` touches only the continuation, which
/// is protected by a lock.
final class AppAudioInputProvider: AudioInputProvider, @unchecked Sendable {

    // MARK: - AudioInputProvider

    private(set) var state: AudioInputState = .idle

    var audioFormat: AVAudioFormat { get async throws { format } }

    // MARK: - Private

    /// Int16, mono, interleaved. Built once in `init`, which force-unwraps it, so the
    /// format must be valid for the sample rate used.
    private let format: AVAudioFormat
    /// Bytes per frame: 2 for Int16 mono. Used to check the size of incoming data.
    private let bytesPerFrame: Int
    /// Protects the current stream continuation. `enqueue(_:)` (any thread) and
    /// `start()`/`stop()` both use it.
    private let continuationLock = OSAllocatedUnfairLock<
        AsyncStream<AVAudioPCMBuffer>.Continuation?
    >(initialState: nil)
    private let logger = Logger(subsystem: "com.voiceaikit", category: "AppAudioInputProvider")

    // MARK: - Init

    /// - Parameter sampleRate: sample rate of the Int16 mono PCM the host will push,
    ///   e.g. `16_000`. If it is not greater than 0, `16_000` is used.
    init(sampleRate: Double) {
        let rate = sampleRate > 0 ? sampleRate : 16_000
        // Int16 / mono / interleaved is a universally valid PCM format description.
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: rate,
            channels: 1,
            interleaved: true
        )!
        self.bytesPerFrame = 2
    }

    // MARK: - AudioInputProvider

    /// Opens a new buffer stream for one turn. It keeps only the newest 32 buffers;
    /// if the consumer is slow, the oldest buffers are dropped.
    func start() -> AsyncStream<AVAudioPCMBuffer> {
        state = .preparing
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        continuationLock.withLock { existing in
            existing?.finish()   // defensively close any prior turn's stream
            existing = continuation
        }
        state = .active
        logger.info("AppAudioInputProvider started (sampleRate: \(self.format.sampleRate) Hz).")
        return stream
    }

    /// Ends the current turn's stream. Audio pushed after this, until the next
    /// `start()`, is dropped.
    func stop() {
        continuationLock.withLock { c in
            c?.finish()
            c = nil
        }
        state = .stopped
        logger.info("AppAudioInputProvider stopped.")
    }

    // MARK: - Push API

    /// Pushes one chunk of raw **Int16 mono** PCM at the configured sample rate.
    ///
    /// Thread-safe. The bytes are copied, so the caller can reuse its storage
    /// immediately. It allocates memory for every chunk, so do not call it directly from
    /// a real-time audio callback. Hand the data to a normal thread or queue first.
    ///
    /// The chunk is dropped when:
    ///   - no turn is active (between turns, or before `start()`),
    ///   - the chunk is empty or smaller than one frame, or
    ///   - the buffer cannot be allocated.
    ///
    /// Send whole frames (an even number of bytes). If the byte count is odd, the last
    /// byte is dropped and a debug message is logged. It is not kept for the next chunk.
    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }

        // Check for an active turn under the lock. If `stop()` finishes the stream right
        // after this, `yield` on the finished stream does nothing.
        let continuation = continuationLock.withLock { $0 }
        guard let continuation else { return }   // dropped between turns

        let remainder = data.count % bytesPerFrame
        if remainder != 0 {
            logger.debug("enqueue: \(data.count) bytes not frame-aligned (Int16 mono) — truncating \(remainder) trailing byte(s).")
        }
        let usableBytes = data.count - remainder
        let frameCount = AVAudioFrameCount(usableBytes / bytesPerFrame)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let dst = buffer.int16ChannelData?[0] else { return }

        buffer.frameLength = frameCount
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let src = raw.baseAddress else { return }
            memcpy(dst, src, usableBytes)
        }
        continuation.yield(buffer)
    }
}
