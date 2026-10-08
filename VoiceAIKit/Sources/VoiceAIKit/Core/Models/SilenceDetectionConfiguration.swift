// SilenceDetectionConfiguration.swift
// VoiceAIKit
//
// Settings that decide when a listening turn ends on its own.

import Foundation

/// Settings for ending a turn automatically after the user stops speaking.
///
/// Three parts use these settings:
///   - The transcript check (`EndpointDecider`) ends the turn when the transcript has
///     not changed for a set time. This decides when the user has finished speaking.
///     How long it waits depends on the answer: `speechEndTimeout`,
///     `freeformAnswerTimeout` or `incompleteAnswerTimeout`.
///   - The no-speech check (`SilenceDetector`) measures how loud each audio buffer is.
///     It ends the turn after `noSpeechTimeout` if nobody speaks.
///   - `maxUtteranceDuration` is an upper limit on one turn.
///
/// `VoiceIntentSession` uses `.singleUtterance` for a new command and `.slotAnswer`
/// when it waits for the answer to a follow-up question. To change them, set
/// `VoiceIntentConfiguration.commandSilence` or `slotAnswerSilence`.
public struct SilenceDetectionConfiguration: Sendable, Equatable {

    /// Whether automatic ending is on. When `false`, the turn runs until it is
    /// stopped manually (for example, continuous captioning).
    public var isEnabled: Bool

    /// A buffer quieter than this level (dBFS) counts as silent. This is the lowest
    /// level the detector uses. In a noisy room the detector raises the level above
    /// this (see `noiseFloorMarginDB`), but never below it.
    public var thresholdDBFS: Float

    /// How many dB a buffer must be above the measured background noise to count as
    /// speech. The level used is `max(thresholdDBFS, noise level + noiseFloorMarginDB)`.
    /// A higher value needs louder speech. A lower value reacts to quieter sounds, but
    /// background noise is more likely to count as speech.
    public var noiseFloorMarginDB: Float

    /// The background noise level (dBFS) assumed at the start of a turn, before any
    /// audio is measured. The detector then adjusts it up or down from the audio.
    public var initialNoiseFloorDBFS: Float

    /// The base wait of the transcript check: seconds the transcript must stay unchanged
    /// before the turn ends, when the answer looks complete.
    public var speechEndTimeout: TimeInterval

    /// Wait for a free-text answer whose end is unclear ("drink" vs "drink water").
    /// The transcript check uses the larger of this and `speechEndTimeout`. It is used
    /// only when the session has an endpoint arbiter, which `VoiceIntentSession` sets.
    public var freeformAnswerTimeout: TimeInterval

    /// Wait for an answer that looks unfinished (for example "tomorrow" when a time is
    /// needed, or a trailing function word). It gives the user time to finish
    /// ("... at 5 AM"). Used only when the session has an endpoint arbiter.
    public var incompleteAnswerTimeout: TimeInterval

    /// Seconds after the turn starts with no speech detected that end the turn.
    /// The turn ends only if the recogniser has produced no text.
    public var noSpeechTimeout: TimeInterval

    /// Upper limit for one turn, counted from the first speech. It only matters when
    /// speech never stops (for example a TV in the background). After this time, the
    /// turn ends once the transcript has not changed for `maxUtteranceWordBoundaryGrace`.
    /// If it keeps changing, the turn ends after `maxUtteranceHardCeiling` more seconds.
    /// `0` turns the limit off.
    public var maxUtteranceDuration: TimeInterval

    /// After `maxUtteranceDuration`, seconds the transcript must stay unchanged before
    /// the turn ends. This makes the turn end between words, not in the middle of one.
    public var maxUtteranceWordBoundaryGrace: TimeInterval

    /// After `maxUtteranceDuration`, the number of extra seconds after which the turn
    /// ends even if the transcript is still changing.
    public var maxUtteranceHardCeiling: TimeInterval

    /// When true, the wait grows the longer the user has been speaking, so a short
    /// command ends quickly and a long sentence is not cut at a pause.
    /// The wait is `min(adaptiveMaxWindow, base + max(0, spokenFor - adaptiveGraceStart) * adaptiveSlope)`,
    /// where `base` is `speechEndTimeout`, `freeformAnswerTimeout` or `incompleteAnswerTimeout`.
    public var adaptiveEndpointing: Bool
    /// The wait does not grow until the user has spoken this many seconds.
    public var adaptiveGraceStart: TimeInterval
    /// Seconds added to the wait for each second spoken after `adaptiveGraceStart`.
    public var adaptiveSlope: Double
    /// The longest wait when `adaptiveEndpointing` is on, in seconds. It also applies
    /// to `incompleteAnswerTimeout`, so a value below it shortens that wait.
    public var adaptiveMaxWindow: TimeInterval

    /// All settings except `isEnabled` have defaults.
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

    /// Automatic ending is off. The turn runs until it is stopped manually.
    public static let disabled = SilenceDetectionConfiguration(isEnabled: false)

    /// Automatic ending for a new command. A short command ends after 1.0 s of quiet.
    /// With `adaptiveEndpointing`, the wait grows for a long sentence (up to
    /// `adaptiveMaxWindow`, 2.5 s). An unfinished answer waits `incompleteAnswerTimeout`
    /// (2.5 s). For slower speakers, use your own configuration with a longer
    /// `speechEndTimeout` (for example 1.2 s).
    public static let singleUtterance = SilenceDetectionConfiguration(
        isEnabled: true,
        speechEndTimeout: 1.0,
        adaptiveEndpointing: true
    )

    /// Automatic ending for the answer to a follow-up question. It waits 1.5 s
    /// (`speechEndTimeout` and `freeformAnswerTimeout`), because people often pause
    /// in the middle of an answer. An unfinished answer still waits
    /// `incompleteAnswerTimeout`. `adaptiveEndpointing` is off.
    public static let slotAnswer = SilenceDetectionConfiguration(
        isEnabled: true,
        speechEndTimeout: 1.5,
        freeformAnswerTimeout: 1.5
    )
}
