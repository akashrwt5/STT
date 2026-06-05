// TranscriptionResult.swift
// STT
//
// Value type encapsulating a single transcription output.

import Foundation

/// A single transcription output, which may be partial (in-progress) or final (committed).
public struct TranscriptionResult: Identifiable, Sendable {
    public let id: UUID
    /// The transcribed text for this segment.
    public let text: String
    /// When false, this result may still change as the recognizer refines its output.
    public let isFinal: Bool
    /// The locale used to produce this result.
    public let locale: Locale
    /// Wall-clock time this result was produced.
    public let timestamp: Date
    /// Duration of the audio segment that produced this result, if known.
    public let audioDuration: TimeInterval?
    /// Confidence score in 0.0–1.0 range, if provided by the recognizer.
    public let confidence: Float?
    /// Intent classification result, populated after a final transcript is classified.
    public var intentResult: IntentResult?

    public init(
        id: UUID = UUID(),
        text: String,
        isFinal: Bool,
        locale: Locale,
        timestamp: Date = Date(),
        audioDuration: TimeInterval? = nil,
        confidence: Float? = nil,
        intentResult: IntentResult? = nil
    ) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
        self.locale = locale
        self.timestamp = timestamp
        self.audioDuration = audioDuration
        self.confidence = confidence
        self.intentResult = intentResult
    }
}
