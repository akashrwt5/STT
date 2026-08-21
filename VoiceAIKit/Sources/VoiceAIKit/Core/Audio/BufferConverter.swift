// BufferConverter.swift
// STT
//
// Converts AVAudioPCMBuffers between formats for the speech analyzer.

import AVFoundation

/// Converts `AVAudioPCMBuffer`s from a source format to the format required by
/// `SpeechAnalyzer` (commonly 16-bit signed integer PCM).
///
/// `SpeechAnalyzer` enforces a strict input format — feeding it mismatched audio
/// triggers "Audio sample data must be 16-bit signed integers" at runtime. This
/// helper bridges the gap between the capture format (e.g. 48 kHz Float32 from the
/// mic) and the analyzer's required format.
final class BufferConverter {

    enum ConversionError: Error {
        case failedToCreateConverter
        case failedToCreateOutputBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    /// Converts `buffer` to `format`, reusing the underlying converter when possible.
    ///
    /// - Returns: A new buffer in the target format, or the original buffer if it
    ///   already matches.
    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        // (Re)create the converter when the input or output format changes.
        if converter == nil
            || converter?.inputFormat != inputFormat
            || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none // sacrifice quality edge frames for stream stability
        }

        guard let converter else { throw ConversionError.failedToCreateConverter }

        // Account for sample-rate differences when sizing the output buffer.
        let sampleRateRatio = format.sampleRate / inputFormat.sampleRate
        let estimatedCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * sampleRateRatio).rounded(.up)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: max(estimatedCapacity, 1)
        ) else {
            throw ConversionError.failedToCreateOutputBuffer
        }

        var didFeedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if didFeedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didFeedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if status == .error || conversionError != nil {
            throw ConversionError.conversionFailed(conversionError)
        }
        return outputBuffer
    }
}
