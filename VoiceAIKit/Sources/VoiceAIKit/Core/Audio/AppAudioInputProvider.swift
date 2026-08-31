// AppAudioInputProvider.swift
// VoiceAIKit
//
// Single responsibility: a push-based `AudioInputProvider` for host apps that own
// the microphone and audio session themselves and feed us raw PCM.

@preconcurrency import AVFoundation
import os
import os.log

/// An `AudioInputProvider` the host app pushes audio into, instead of the package
/// opening the microphone.
///
/// Used when a session is created with `audioSource == .appProvided`. The host owns
/// the `AVAudioSession`, the microphone (or hearing-aid route), permissions, and
/// interruptions; it simply calls `enqueue(_:)` with chunks of raw PCM as they arrive.
///
/// Audio contract (fixed for this provider): **Int16, mono, interleaved** at the
/// sample rate given at construction. This matches the host's converter
/// (`buffer.int16ChannelData`, single channel). `SpeechRecognitionService` converts
/// these buffers to whatever format the `SpeechAnalyzer` requires downstream.
///
/// Lifecycle mirrors the live mic: the coordinator calls `start()` when a turn opens
/// and `stop()` when it endpoints. Audio pushed between turns (no active stream) is
/// dropped, so trailing audio from one turn can't bleed into the next.
final class AppAudioInputProvider: AudioInputProvider, @unchecked Sendable {

    // MARK: - AudioInputProvider

    private(set) var state: AudioInputState = .idle

    var audioFormat: AVAudioFormat { get async throws { format } }

    // MARK: - Private

    /// Int16 / mono / interleaved at the host's sample rate. Always constructible for
    /// these parameters, so the force-unwrap cannot fail in practice.
    private let format: AVAudioFormat
    /// Bytes per audio frame — 2 for Int16 mono. Used to validate/align incoming Data.
    private let bytesPerFrame: Int
    /// Guards the active continuation so `enqueue(_:)` (called from the host's
    /// real-time audio thread) and `start()`/`stop()` never race on it.
    private let continuationLock = OSAllocatedUnfairLock<
        AsyncStream<AVAudioPCMBuffer>.Continuation?
    >(initialState: nil)
    private let logger = Logger(subsystem: "com.voiceaikit", category: "AppAudioInputProvider")

    // MARK: - Init

    /// - Parameter sampleRate: sample rate of the Int16 mono PCM the host will push
    ///   (e.g. 16_000 for a BLE / hearing-aid stream).
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

    /// Opens a fresh buffer stream for one recognition turn. Bounded so a slow
    /// consumer can never grow memory without limit — the newest audio wins, which
    /// is the correct policy for live speech (stale backlog is worthless).
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

    /// Ends the current turn's stream. Audio pushed after this (until the next
    /// `start()`) is dropped.
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
    /// Safe to call from any thread, including a real-time audio callback. The bytes
    /// are deep-copied into an owned buffer before being handed off, so the caller may
    /// reuse its own storage immediately.
    ///
    /// Dropped (no-op) when:
    ///   - no turn is active (between turns / before `start()`), or
    ///   - the chunk is empty.
    /// A non-frame-aligned byte count (odd, for Int16) is truncated to whole frames
    /// and the remainder logged — it never crashes or builds a malformed buffer.
    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }

        // Only build/yield if a turn is active. Snapshot under the lock; yielding to a
        // continuation that stop() finishes right after is a safe no-op.
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
