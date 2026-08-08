// EndpointDecider.swift
// VoiceIntentKit
//
// The pure, clock-free endpointing math, lifted out of `SpeechRecognitionService`
// so it can be unit-tested without a live `SpeechAnalyzer`, microphone, or wall
// clock. Every time value is passed in explicitly; the struct holds no mutable
// state and never reads the clock itself.
//
// `SpeechRecognitionService` keeps the state (flags, timestamps), the clock, and the
// async content-aware arbiter; it delegates the actual "should we endpoint now?"
// decisions here. The three methods below mirror, one-for-one, the logic that used
// to live inline in the recognizer.

import Foundation

struct EndpointDecider {

    let config: SilenceDetectionConfiguration

    /// The trailing-silence window required to endpoint for a given content-aware
    /// verdict: complete commits fast, freeform gets a medium window, a verifiably
    /// unfinished answer gets the extended one.
    func requiredStabilityWindow(for verdict: SlotAnswerAssessment) -> TimeInterval {
        switch verdict {
        case .complete:   return config.speechEndTimeout
        case .freeform:   return max(config.speechEndTimeout, config.freeformAnswerTimeout)
        case .incomplete: return config.incompleteAnswerTimeout
        }
    }

    /// Transcript-stability endpoint: true once the running transcript has been
    /// unchanged for the verdict's window. `lastChangeAt` is when it last changed.
    func shouldEndpointForStableTranscript(
        now: CFAbsoluteTime,
        lastChangeAt: CFAbsoluteTime,
        hasVolatileText: Bool,
        hasReceivedFinalResult: Bool,
        verdict: SlotAnswerAssessment
    ) -> Bool {
        guard hasVolatileText, !hasReceivedFinalResult, lastChangeAt > 0 else { return false }
        return now - lastChangeAt >= requiredStabilityWindow(for: verdict)
    }

    /// Runaway guard, word-boundary aware. Fires only once speech has run past
    /// `maxUtteranceDuration` from `firstSpeechAt`; at the soft cap it waits for a
    /// micro-gap (so it never cuts mid-word), with a hard ceiling beyond that as the
    /// absolute backstop for input that never gaps at all. `maxUtteranceDuration == 0`
    /// disables it.
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

    /// Whether an acoustic-VAD outcome should end the session. Config-independent, so
    /// it is `static`.
    ///
    /// `.noSpeech` ends only when the decoder produced no text (nobody spoke); if there
    /// IS text, a quiet speaker under AGC is likely below the energy threshold — defer
    /// to the content-aware stability endpoint. `.endOfSpeech` ends once the user has
    /// produced any text (volatile or final).
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
