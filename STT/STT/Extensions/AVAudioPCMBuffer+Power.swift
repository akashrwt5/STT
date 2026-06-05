// AVAudioPCMBuffer+Power.swift
// STT
//
// Audio energy measurement for Voice Activity Detection.

import AVFoundation

extension AVAudioPCMBuffer {

    /// The average power of the buffer's first channel, in dBFS (decibels relative
    /// to full scale). Returns a value in the range `(-∞, 0]`, where `0` is the
    /// loudest representable signal and large negative values indicate silence.
    ///
    /// Computed as `20 * log10(rms)` over the channel samples. Supports the float
    /// and 16-bit integer PCM formats used across the pipeline (mic capture is
    /// Float32; the analyzer format is Int16). Returns `-.infinity` for an empty or
    /// unsupported buffer.
    func averagePowerDBFS(channel: Int = 0) -> Float {
        let frames = Int(frameLength)
        guard frames > 0 else { return -.infinity }

        let rms: Float
        if let floatData = floatChannelData {
            rms = Self.rootMeanSquare(floatData[channel], count: frames)
        } else if let int16Data = int16ChannelData {
            // Normalise Int16 samples to the [-1, 1] range before computing RMS.
            var sumSquares: Float = 0
            let scale = Float(Int16.max)
            for i in 0..<frames {
                let sample = Float(int16Data[channel][i]) / scale
                sumSquares += sample * sample
            }
            rms = (sumSquares / Float(frames)).squareRoot()
        } else {
            return -.infinity
        }

        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }

    private static func rootMeanSquare(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        var sumSquares: Float = 0
        for i in 0..<count {
            let sample = samples[i]
            sumSquares += sample * sample
        }
        return (sumSquares / Float(count)).squareRoot()
    }
}
