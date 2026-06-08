// SilenceDetector.swift
// STT
//
// Energy-based Voice Activity Detection (VAD) for automatic session termination.

import AVFoundation
import os.log

/// Tracks audio energy across a stream of buffers and decides when enough silence
/// has elapsed to end a transcription session.
///
/// This is the on-device equivalent of the platform-managed endpointing offered by
/// cloud services (e.g. Dialogflow's `single_utterance`). It runs *before* the
/// `SpeechAnalyzer` ever sees the audio: a cheap RMS power calculation per buffer,
/// with two timeouts (`speechEndTimeout` and `noSpeechTimeout`) that model the
/// "trailed off after speaking" and "never spoke" cases respectively.
///
/// Not thread-safe by design — it is fed sequentially from a single feed task and
/// holds simple mutable counters, so it carries no synchronisation overhead.
final class SilenceDetector {

    /// The verdict after processing a buffer.
    enum Outcome: Equatable {
        /// Keep listening — not enough silence has elapsed.
        case ongoing
        /// Enough silence elapsed; the session should end.
        case silenceDetected(reason: Reason)

        enum Reason: Equatable {
            /// Silence after the user finished an utterance.
            case endOfSpeech
            /// No speech was ever detected within the no-speech window.
            case noSpeech
        }
    }

    private let configuration: SilenceDetectionConfiguration
    private let sampleRate: Double
    private let logger = Logger(subsystem: "com.stt.module", category: "SilenceDetector")

    /// Whether any above-threshold (speech) buffer has been seen yet.
    private var hasDetectedSpeech = false
    /// Number of consecutive silent frames since the last speech frame.
    private var consecutiveSilentFrames: Int = 0
    /// Total frames seen, used for the no-speech timeout.
    private var totalFrames: Int = 0
    /// Guards against firing `.silenceDetected` more than once per session.
    private var hasFired = false

    /// - Parameters:
    ///   - configuration: Thresholds and timeouts.
    ///   - sampleRate: Sample rate of the buffers being fed, used to convert frame
    ///     counts into elapsed seconds.
    init(configuration: SilenceDetectionConfiguration, sampleRate: Double) {
        self.configuration = configuration
        self.sampleRate = sampleRate > 0 ? sampleRate : 16_000
    }

    /// Feeds one buffer and returns whether the session should now end.
    func process(_ buffer: AVAudioPCMBuffer) -> Outcome {
        guard configuration.isEnabled, !hasFired else { return .ongoing }

        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return .ongoing }

        totalFrames += frames
        let power = buffer.averagePowerDBFS()

        if power >= configuration.thresholdDBFS {
            // Speech present — reset the silence run.
            if !hasDetectedSpeech {
                logger.info("[VAD] First speech detected (power: \(power) dBFS).")
            }
            hasDetectedSpeech = true
            consecutiveSilentFrames = 0
            return .ongoing
        }

        // Buffer is silent — accumulate.
        consecutiveSilentFrames += frames

        if hasDetectedSpeech {
            let silentSeconds = Double(consecutiveSilentFrames) / sampleRate
            if silentSeconds >= configuration.speechEndTimeout {
                logger.info("[VAD] End-of-speech silence reached (\(silentSeconds)s ≥ \(self.configuration.speechEndTimeout)s).")
                hasFired = true
                return .silenceDetected(reason: .endOfSpeech)
            }
        } else {
            let elapsedSeconds = Double(totalFrames) / sampleRate
            if elapsedSeconds >= configuration.noSpeechTimeout {
                logger.info("[VAD] No-speech timeout reached (\(elapsedSeconds)s ≥ \(self.configuration.noSpeechTimeout)s).")
                hasFired = true
                return .silenceDetected(reason: .noSpeech)
            }
        }

        return .ongoing
    }
}
