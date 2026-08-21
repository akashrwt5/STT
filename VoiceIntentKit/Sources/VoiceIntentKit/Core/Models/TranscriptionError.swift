// TranscriptionError.swift
// STT
//
// Typed error domain for the entire STT pipeline.

import Foundation

/// All failure modes that can occur during transcription setup or runtime.
enum TranscriptionError: LocalizedError, Sendable {
    case microphonePermissionDenied
    case speechRecognitionPermissionDenied
    case localeNotSupported(String)
    case audioSessionSetupFailed(Error)
    case audioEngineStartFailed(Error)
    case fileNotFound(URL)
    case unsupportedAudioFormat(String)
    case analyzerFailed(Error)
    /// Returned when `SpeechTranscriber.supportsDevice()` returns false.
    case deviceNotSupported
    /// A transcription session is already running; concurrent live + file sessions
    /// would corrupt the shared recognition pipeline.
    case sessionAlreadyActive

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required. Enable it in Settings → Privacy → Microphone."
        case .speechRecognitionPermissionDenied:
            return "Speech recognition access is required. Enable it in Settings → Privacy → Speech Recognition."
        case .localeNotSupported(let id):
            return "The locale '\(id)' is not supported by the on-device speech recognizer."
        case .audioSessionSetupFailed(let err):
            return "Audio session setup failed: \(err.localizedDescription)"
        case .audioEngineStartFailed(let err):
            return "Audio engine failed to start: \(err.localizedDescription)"
        case .fileNotFound(let url):
            return "Audio file not found at path: \(url.lastPathComponent)"
        case .unsupportedAudioFormat(let format):
            return "The audio format '\(format)' is not supported for transcription."
        case .analyzerFailed(let err):
            return "Speech analyzer encountered an error: \(err.localizedDescription)"
        case .deviceNotSupported:
            return "On-device speech recognition is not supported on this device."
        case .sessionAlreadyActive:
            return "A transcription session is already in progress. Stop it before starting another."
        }
    }
}
