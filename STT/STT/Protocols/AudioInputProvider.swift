// AudioInputProvider.swift
// STT
//
// Open/closed abstraction for any audio source feeding the speech analyzer.

import AVFoundation

/// Abstraction for any source of audio buffers consumed by `SpeechRecognitionService`.
///
/// Conforming types are fully interchangeable — the recognition service does not know
/// whether audio originates from a live microphone, an audio file, or a network stream.
///
/// Providers emit **raw** `AVAudioPCMBuffer`s in their natural capture format.
/// `SpeechRecognitionService` is responsible for converting them to the format the
/// `SpeechAnalyzer` requires (it is the only component that knows that format).
public protocol AudioInputProvider: Sendable {
    /// The natural format this provider produces buffers in.
    ///
    /// - Throws: `TranscriptionError.audioSessionSetupFailed` or format-negotiation errors.
    var audioFormat: AVAudioFormat { get async throws }

    /// Begin producing raw audio buffers.
    ///
    /// - Returns: An `AsyncStream` of `AVAudioPCMBuffer`. The stream terminates
    ///   naturally when the source is exhausted (file) or when `stop()` is called (mic).
    func start() -> AsyncStream<AVAudioPCMBuffer>

    /// Signal the provider to stop producing buffers and release audio resources.
    func stop()

    /// Current lifecycle state of this provider.
    var state: AudioInputState { get }

    /// Optional stream of completion progress in the range 0.0...1.0.
    ///
    /// Finite sources (files) report real progress here; open-ended sources (the live
    /// microphone) return `nil`. Consumed once per `start()`.
    var progressStream: AsyncStream<Double>? { get }
}

public extension AudioInputProvider {
    /// Default: no progress reporting (suitable for open-ended sources like the mic).
    var progressStream: AsyncStream<Double>? { nil }
}
