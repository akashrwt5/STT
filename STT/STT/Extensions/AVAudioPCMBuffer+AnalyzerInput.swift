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
}
