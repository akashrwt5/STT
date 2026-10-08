// EndpointDecider.swift
// VoiceAIKit
//
// Decides when a turn should end, from the transcript and the time values passed in.

import Foundation

/// The rules for ending a turn. It holds no state and does not read the clock.
/// `SpeechRecognitionService` keeps the state and the clock, and passes the times in.
/// This makes the rules easy to test without a microphone or a `SpeechAnalyzer`.
struct EndpointDecider {

    /// The silence settings used by the rules.
    let config: SilenceDetectionConfiguration

    /// How long the transcript must stay unchanged before the turn ends, for the
    /// given verdict:
    ///   - `.complete`: `speechEndTimeout`
    ///   - `.freeform`: the larger of `speechEndTimeout` and `freeformAnswerTimeout`
    ///   - `.incomplete`: `incompleteAnswerTimeout`
    ///
    /// When `adaptiveEndpointing` is on, the wait is longer for a long utterance:
    /// `min(adaptiveMaxWindow, wait + max(0, spokenFor - adaptiveGraceStart) * adaptiveSlope)`.
    /// The result is never more than `adaptiveMaxWindow`.
    ///
    /// - Parameter spokenFor: Seconds since the first text arrived. Pass `0` if unknown.
    func requiredStabilityWindow(
        for verdict: SlotAnswerAssessment,
        spokenFor: TimeInterval = 0
    ) -> TimeInterval {
        let base: TimeInterval
        switch verdict {
        case .complete:   base = config.speechEndTimeout
        case .freeform:   base = max(config.speechEndTimeout, config.freeformAnswerTimeout)
        case .incomplete: base = config.incompleteAnswerTimeout
        }
        guard config.adaptiveEndpointing else { return base }
        let ext = max(0, spokenFor - config.adaptiveGraceStart) * config.adaptiveSlope
        return min(config.adaptiveMaxWindow, base + ext)
    }

    /// Returns true when the transcript has not changed for the required window
    /// (see `requiredStabilityWindow`).
    ///
    /// It returns false when there is no text yet, when the final result has already
    /// arrived, or when `lastChangeAt` is `0` (the transcript has not changed yet).
    ///
    /// - Parameters:
    ///   - lastChangeAt: When the transcript last changed.
    ///   - firstSpeechAt: When the first text arrived. `0` means no text yet. Used for
    ///     the adaptive window.
    func shouldEndpointForStableTranscript(
        now: CFAbsoluteTime,
        lastChangeAt: CFAbsoluteTime,
        hasVolatileText: Bool,
        hasReceivedFinalResult: Bool,
        verdict: SlotAnswerAssessment,
        firstSpeechAt: CFAbsoluteTime = 0
    ) -> Bool {
        guard hasVolatileText, !hasReceivedFinalResult, lastChangeAt > 0 else { return false }
        let spokenFor = firstSpeechAt > 0 ? now - firstSpeechAt : 0
        return now - lastChangeAt >= requiredStabilityWindow(for: verdict, spokenFor: spokenFor)
    }

    /// Returns true when the turn has lasted too long. This is the upper limit set by
    /// `maxUtteranceDuration`, counted from `firstSpeechAt` (the first text).
    ///   - Before `maxUtteranceDuration` seconds: false.
    ///   - After it: true once the transcript has not changed for
    ///     `maxUtteranceWordBoundaryGrace`, so the turn ends between words.
    ///   - After `maxUtteranceDuration + maxUtteranceHardCeiling`: always true.
    /// It is always false when `maxUtteranceDuration` is `0`, when there is no text,
    /// or when the final result has arrived.
    func shouldEndpointForMaxDuration(
        now: CFAbsoluteTime,
        firstSpeechAt: CFAbsoluteTime,
        lastChangeAt: CFAbsoluteTime,
        hasVolatileText: Bool,
        hasReceivedFinalResult: Bool
    ) -> Bool {
        guard config.maxUtteranceDuration > 0,
              hasVolatileText, !hasReceivedFinalResult, firstSpeechAt > 0
        else { return false }

        let spokenFor = now - firstSpeechAt
        guard spokenFor >= config.maxUtteranceDuration else { return false }

        let hardCeiling = config.maxUtteranceDuration + config.maxUtteranceHardCeiling
        if spokenFor >= hardCeiling { return true }
        return now - lastChangeAt >= config.maxUtteranceWordBoundaryGrace
    }

    /// Whether a result from the audio check (`SilenceDetector`) should end the turn.
    /// It does not depend on the settings, so it is `static`. The session currently passes
    /// only `.noSpeech`.
    ///   - `.noSpeech`: ends the turn only if there is no text. If there is text, the
    ///     microphone level may just be below the threshold, so the transcript check
    ///     decides instead.
    ///   - `.endOfSpeech`: ends the turn once there is any text, partial or final.
    static func shouldStop(
        for reason: SilenceDetector.Outcome.Reason,
        hasVolatileText: Bool,
        hasReceivedFinalResult: Bool
    ) -> Bool {
        switch reason {
        case .noSpeech:    return !hasVolatileText
        case .endOfSpeech: return hasReceivedFinalResult || hasVolatileText
        }
    }
}
