// AVAudioPCMBuffer+AnalyzerInput.swift
// STT
//
// Convenience bridge between AVAudioPCMBuffer and AnalyzerInput.

import AVFoundation
import Speech

extension AVAudioPCMBuffer {
    /// Creates an `AnalyzerInput` from this buffer.
    ///
    /// Timing is derived from the buffer's own `AVAudioTime` as set by the audio engine
    /// tap or file reader — do not pass an external audioTime, as `AnalyzerInput` does
    /// not expose that parameter in the iOS 26 API.
    func analyzerInput() -> AnalyzerInput {
        AnalyzerInput(buffer: self)
    }

    /// Returns an independent deep copy of this buffer.
    ///
    /// Buffers handed to an `AVAudioNode` tap callback are only valid for the duration
    /// of that callback — the engine may reuse the backing storage afterwards. When a
    /// buffer is yielded into an `AsyncStream` for later consumption, it MUST be copied
    /// first, or the consumer can read corrupted/overwritten audio samples.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength
        let channelCount = Int(format.channelCount)
        let frames = Int(frameLength)

        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size)
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size)
            }
        } else if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Int32>.size)
            }
        } else {
            return nil
        }
        return copy
    }
}
