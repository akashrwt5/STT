// AudioInputProvider.swift
// STT
//
// Open/closed abstraction for any audio source feeding the speech analyzer.

import AVFoundation
import Speech

/// Abstraction for any source of `AnalyzerInput` buffers consumed by `SpeechRecognitionService`.
///
/// Conforming types are fully interchangeable — the recognition service does not know
/// whether audio originates from a live microphone, an audio file, or a network stream.
public protocol AudioInputProvider: Sendable {
    /// The audio format this provider will produce.
    ///
    /// - Throws: `TranscriptionError.audioSessionSetupFailed` or format-negotiation errors.
    var audioFormat: AVAudioFormat { get async throws }

    /// Begin producing audio buffers.
    ///
    /// - Returns: An `AsyncStream` of `AnalyzerInput` values. The stream terminates
    ///   naturally when the source is exhausted (file) or when `stop()` is called (mic).
    func start() -> AsyncStream<AnalyzerInput>

    /// Signal the provider to stop producing buffers and release audio resources.
    func stop()

    /// Current lifecycle state of this provider.
    var state: AudioInputState { get }
}
