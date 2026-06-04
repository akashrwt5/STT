// AVAudioPCMBuffer+AnalyzerInput.swift
// STT
//
// Convenience bridge between AVAudioPCMBuffer and AnalyzerInput.

import AVFoundation
import Speech

extension AVAudioPCMBuffer {
    /// Creates an `AnalyzerInput` from this buffer with the given start time.
    ///
    /// - Parameter bufferStartTime: The time (in seconds from session start) at which
    ///   the first sample in this buffer was captured. Must be calculated from
    ///   accumulated frame counts — not wall clock time.
    /// - Returns: An `AnalyzerInput` suitable for passing to `SpeechAnalyzer`.
    func analyzerInput(bufferStartTime: TimeInterval) -> AnalyzerInput {
        AnalyzerInput(buffer: self, audioTime: AVAudioTime(
            sampleTime: AVAudioFramePosition(bufferStartTime * Double(format.sampleRate)),
            atRate: format.sampleRate
        ))
    }
}
