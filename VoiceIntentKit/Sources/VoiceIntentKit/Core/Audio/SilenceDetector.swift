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
    private let logger = Logger(subsystem: "com.voiceintentkit", category: "SilenceDetector")

    /// Whether any above-threshold (speech) buffer has been seen yet.
    private var hasDetectedSpeech = false
    /// Number of consecutive silent frames since the last speech frame.
    private var consecutiveSilentFrames: Int = 0
    /// Total frames seen, used for the no-speech timeout.
    private var totalFrames: Int = 0
    /// Slow EMA of the ambient noise floor (dBFS), learned from silent buffers.
    /// A fixed threshold breaks under `.playAndRecord` (no `.measurement` mode, so
    /// AGC/processing applies) and across routes — built-in mic vs HFP hearing aids
    /// report very different levels for the same room. Seeded at a quiet-room value.
    private var noiseFloorDBFS: Float = -60
    /// Margin above the learned noise floor required to count as speech.
    private let noiseMarginDB: Float = 12

    /// The threshold actually applied: never *below* the configured floor (so a very
    /// quiet room doesn't make breathing count as speech), but rises with ambient
    /// noise so a loud room doesn't make the silence timer never fire.
    private var effectiveThresholdDBFS: Float {
        max(configuration.thresholdDBFS, noiseFloorDBFS + noiseMarginDB)
    }

    /// - Parameters:
    ///   - configuration: Thresholds and timeouts.
    ///   - sampleRate: Sample rate of the buffers being fed, used to convert frame
    ///     counts into elapsed seconds.
    init(configuration: SilenceDetectionConfiguration, sampleRate: Double) {
        self.configuration = configuration
        self.sampleRate = sampleRate > 0 ? sampleRate : 16_000
    }

    /// Feeds one buffer and returns whether the session should now end.
    /// Convenience overload — computes power itself. Prefer `process(powerDBFS:frames:)`
    /// when the caller has already measured the buffer (avoids a second RMS pass).
    func process(_ buffer: AVAudioPCMBuffer) -> Outcome {
        process(powerDBFS: buffer.averagePowerDBFS(), frames: Int(buffer.frameLength))
    }

    /// Feeds one measurement and returns whether the session should now end.
    func process(powerDBFS power: Float, frames: Int) -> Outcome {
        guard configuration.isEnabled, frames > 0 else { return .ongoing }

        totalFrames += frames

        // Adapt the noise floor from EVERY buffer, asymmetrically: drop fast toward
        // quieter audio, rise slowly (≈ +3.5 dB/s at ~12 buffers/s) toward louder
        // ambient — but never learn from strong speech (> floor + 20 dB). The previous
        // version only learned from buffers already classified silent, so a floor that
        // started below the real ambient level could never rise, the effective
        // threshold stayed too low, ambient noise kept classifying as "speech", and
        // the silence run reset forever — the VAD never fired.
        if power.isFinite {
            if power < noiseFloorDBFS {
                noiseFloorDBFS += (power - noiseFloorDBFS) * 0.2
            } else if power < noiseFloorDBFS + 20 {
                noiseFloorDBFS += min(0.3, (power - noiseFloorDBFS) * 0.05)
            }
        }

        if power >= effectiveThresholdDBFS {
            // Speech present — reset the silence run.
            if !hasDetectedSpeech {
                logger.info("[VAD] First speech detected (power: \(power) dBFS, threshold: \(self.effectiveThresholdDBFS) dBFS).")
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
                return .silenceDetected(reason: .endOfSpeech)
            }
        } else {
            let elapsedSeconds = Double(totalFrames) / sampleRate
            if elapsedSeconds >= configuration.noSpeechTimeout {
                logger.info("[VAD] No-speech timeout reached (\(elapsedSeconds)s ≥ \(self.configuration.noSpeechTimeout)s).")
                return .silenceDetected(reason: .noSpeech)
            }
        }

        return .ongoing
    }
}
