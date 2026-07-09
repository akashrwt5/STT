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

    /// Medium window applied when the endpoint arbiter reports FREEFORM — free
    /// text whose completeness cannot be verified ("drink" vs "drink water").
    /// Long enough to survive a mid-topic thinking pause, short enough to stay
    /// responsive. Only consulted when an arbiter is installed.
    public var freeformAnswerTimeout: TimeInterval

    /// Extended window applied when the endpoint arbiter judges the stable
    /// transcript verifiably INCOMPLETE (e.g. bare "tomorrow" for a date-time
    /// slot, a trailing function word). Gives the user room to finish the
    /// thought ("…5 AM") before the turn is committed.
    public var incompleteAnswerTimeout: TimeInterval

    /// Duration of silence *with no speech ever detected* that ends the session.
    public var noSpeechTimeout: TimeInterval

    public init(
        isEnabled: Bool,
        thresholdDBFS: Float = -45.0,
        speechEndTimeout: TimeInterval = 1.0,
        freeformAnswerTimeout: TimeInterval = 1.5,
        incompleteAnswerTimeout: TimeInterval = 2.5,
        noSpeechTimeout: TimeInterval = 5.0
    ) {
        self.isEnabled = isEnabled
        self.thresholdDBFS = thresholdDBFS
        self.speechEndTimeout = speechEndTimeout
        self.freeformAnswerTimeout = freeformAnswerTimeout
        self.incompleteAnswerTimeout = incompleteAnswerTimeout
        self.noSpeechTimeout = noSpeechTimeout
    }

    /// Silence detection off — the session runs until stopped manually.
    /// Use for continuous captioning of an ongoing conversation.
    public static let disabled = SilenceDetectionConfiguration(isEnabled: false)

    /// Silence detection on with sensible defaults — the session ends shortly after
    /// the user stops speaking. Use for command / single-utterance interactions.
    public static let singleUtterance = SilenceDetectionConfiguration(isEnabled: true)

    /// Endpointing for slot answers (replies to a follow-up question). Uses a
    /// uniform, deliberately unhurried 1.5s confirmation window — the original
    /// pre-tuning value. Field testing showed people routinely pause ~1s
    /// mid-answer ("drink… water", "tomorrow… five"), so a fast-commit window
    /// here clips answers more often than it saves time. Verifiably unfinished
    /// answers still extend further via `incompleteAnswerTimeout`.
    public static let slotAnswer = SilenceDetectionConfiguration(
        isEnabled: true,
        speechEndTimeout: 1.5,
        freeformAnswerTimeout: 1.5
    )
}
