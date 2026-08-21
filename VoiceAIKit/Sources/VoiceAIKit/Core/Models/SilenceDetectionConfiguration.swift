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
    /// Acts as the *floor* of the effective threshold — the adaptive noise-floor
    /// estimate can raise the effective threshold above this in a loud room, but
    /// never below it.
    public var thresholdDBFS: Float

    /// Margin in dB above the learned ambient noise floor that a buffer must exceed
    /// to count as speech (effective threshold = max(thresholdDBFS, noiseFloor +
    /// this)). Higher = stricter (louder speech needed to reset the silence timer);
    /// lower = more sensitive but more prone to counting ambient noise as speech.
    public var noiseFloorMarginDB: Float

    /// Seed for the adaptive noise-floor estimate (dBFS) at session start, before
    /// any ambient audio has been observed. A quiet-room default; it adapts upward
    /// on its own in a louder environment.
    public var initialNoiseFloorDBFS: Float

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

    /// Runaway guard — the absolute ceiling on a single turn, measured from the FIRST
    /// detected speech. This is NOT the lever for "how long the mic can hang": that is
    /// already bounded by the trailing-silence windows above (≤ `incompleteAnswerTimeout`
    /// after the user goes quiet). This cap only ever bites when speech never stops
    /// (background TV, dictating an essay into a command mic), so it is set high on
    /// purpose. The endpoint applies it word-boundary-aware — it commits at the next
    /// micro-gap rather than mid-word, with a small hard ceiling beyond this value as a
    /// final backstop. Set to `0` to disable.
    public var maxUtteranceDuration: TimeInterval

    /// Inter-word micro-gap (seconds) that counts as a safe word boundary for the
    /// `maxUtteranceDuration` cap to commit at, so the cap never cuts mid-word.
    public var maxUtteranceWordBoundaryGrace: TimeInterval

    /// Extra time (seconds) beyond `maxUtteranceDuration` after which the cap commits
    /// unconditionally — even mid-word. Absolute backstop for input that never pauses
    /// between words (a continuous stream that offers no word boundary to cut at).
    public var maxUtteranceHardCeiling: TimeInterval

    /// When true, the trailing-silence window GROWS with how long the user has already
    /// been speaking: a short command commits fast (the base window), a long continuous
    /// utterance gets a longer window so sentence-boundary pauses don't cut it off. A
    /// lightweight heuristic stand-in for a neural end-of-query model. Default off.
    public var adaptiveEndpointing: Bool
    /// No adaptive extension until the user has been speaking at least this long (s).
    public var adaptiveGraceStart: TimeInterval
    /// Extra window (seconds) added per second spoken beyond `adaptiveGraceStart`.
    public var adaptiveSlope: Double
    /// Absolute ceiling (seconds) on the adaptive trailing-silence window.
    public var adaptiveMaxWindow: TimeInterval

    public init(
        isEnabled: Bool,
        thresholdDBFS: Float = -45.0,
        noiseFloorMarginDB: Float = 12.0,
        initialNoiseFloorDBFS: Float = -60.0,
        speechEndTimeout: TimeInterval = 1.0,
        freeformAnswerTimeout: TimeInterval = 1.5,
        incompleteAnswerTimeout: TimeInterval = 2.5,
        noSpeechTimeout: TimeInterval = 5.0,
        maxUtteranceDuration: TimeInterval = 60.0,
        maxUtteranceWordBoundaryGrace: TimeInterval = 0.35,
        maxUtteranceHardCeiling: TimeInterval = 3.0,
        adaptiveEndpointing: Bool = false,
        adaptiveGraceStart: TimeInterval = 3.0,
        adaptiveSlope: Double = 0.12,
        adaptiveMaxWindow: TimeInterval = 2.5
    ) {
        self.isEnabled = isEnabled
        self.thresholdDBFS = thresholdDBFS
        self.noiseFloorMarginDB = noiseFloorMarginDB
        self.initialNoiseFloorDBFS = initialNoiseFloorDBFS
        self.speechEndTimeout = speechEndTimeout
        self.freeformAnswerTimeout = freeformAnswerTimeout
        self.incompleteAnswerTimeout = incompleteAnswerTimeout
        self.noSpeechTimeout = noSpeechTimeout
        self.maxUtteranceDuration = maxUtteranceDuration
        self.maxUtteranceWordBoundaryGrace = maxUtteranceWordBoundaryGrace
        self.maxUtteranceHardCeiling = maxUtteranceHardCeiling
        self.adaptiveEndpointing = adaptiveEndpointing
        self.adaptiveGraceStart = adaptiveGraceStart
        self.adaptiveSlope = adaptiveSlope
        self.adaptiveMaxWindow = adaptiveMaxWindow
    }

    /// Silence detection off — the session runs until stopped manually.
    /// Use for continuous captioning of an ongoing conversation.
    public static let disabled = SilenceDetectionConfiguration(isEnabled: false)

    /// Silence detection on — command + natural-language capture. Short utterances
    /// commit at the **1.0s** base window (industry command norm — Alexa/Google sit at
    /// ~0.5–1.0s); a long continuous utterance grows the window via `adaptiveEndpointing`
    /// (up to `adaptiveMaxWindow` = 2.5s) so sentence-boundary pauses don't cut it, and
    /// clearly-unfinished input still extends via `incompleteAnswerTimeout` (2.5s). For
    /// consistently slower speakers (e.g. hearing-aid users) raise `speechEndTimeout` to
    /// ~1.2s via a custom `SilenceDetectionConfiguration`.
    public static let singleUtterance = SilenceDetectionConfiguration(
        isEnabled: true,
        speechEndTimeout: 1.0,
        adaptiveEndpointing: true
    )

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
