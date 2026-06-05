// SilenceDetectionConfiguration.swift
// STT
//
// Tunable parameters for automatic silence-based session termination.

import Foundation

/// Configuration for energy-based Voice Activity Detection (VAD).
///
/// When enabled, the recognition pipeline measures the audio energy of incoming
/// buffers and automatically ends the session after a configurable period of
/// silence — mirroring the platform-managed endpointing of cloud services such
/// as Dialogflow's `single_utterance` mode.
///
/// Two independent timeouts model the two real-world cases:
///   - **`speechEndTimeout`**: silence *after* the user has spoken (they finished
///     their utterance and trailed off).
///   - **`noSpeechTimeout`**: silence from the very start (the session opened but
///     nobody ever spoke).
public struct SilenceDetectionConfiguration: Sendable, Equatable {

    /// Whether automatic silence detection is active. When `false`, the session
    /// runs until stopped manually (suitable for continuous live captioning).
    public var isEnabled: Bool

    /// Energy threshold in dBFS below which a buffer is considered silent.
    ///
    /// Typical speech sits well above −40 dBFS; ambient room noise usually falls
    /// below −50 dBFS. The default of −45 dBFS is a conservative middle ground.
    public var thresholdDBFS: Float

    /// Duration of continuous silence *after detected speech* that ends the session.
    public var speechEndTimeout: TimeInterval

    /// Duration of silence *with no speech ever detected* that ends the session.
    public var noSpeechTimeout: TimeInterval

    public init(
        isEnabled: Bool,
        thresholdDBFS: Float = -45.0,
        speechEndTimeout: TimeInterval = 1.5,
        noSpeechTimeout: TimeInterval = 5.0
    ) {
        self.isEnabled = isEnabled
        self.thresholdDBFS = thresholdDBFS
        self.speechEndTimeout = speechEndTimeout
        self.noSpeechTimeout = noSpeechTimeout
    }

    /// Silence detection off — the session runs until stopped manually.
    /// Use for continuous captioning of an ongoing conversation.
    public static let disabled = SilenceDetectionConfiguration(isEnabled: false)

    /// Silence detection on with sensible defaults — the session ends shortly after
    /// the user stops speaking. Use for command / single-utterance interactions.
    public static let singleUtterance = SilenceDetectionConfiguration(isEnabled: true)
}
