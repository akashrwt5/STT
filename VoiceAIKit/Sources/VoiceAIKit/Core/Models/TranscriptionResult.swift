// TranscriptionResult.swift
// STT
//
// Value type encapsulating a single transcription output.

import Foundation

/// A single transcription output, which may be partial (in-progress) or final (committed).
struct TranscriptionResult: Identifiable, Sendable {
    let id: UUID
    /// The transcribed text for this segment.
    let text: String
    /// When false, this result may still change as the recognizer refines its output.
    let isFinal: Bool
    /// The locale used to produce this result.
    let locale: Locale
    /// Wall-clock time this result was produced.
    let timestamp: Date
    /// Duration of the audio segment that produced this result, if known.
    let audioDuration: TimeInterval?
    /// Confidence score in 0.0–1.0 range, if provided by the recognizer.
    let confidence: Float?
    /// Intent classification result, populated after a final transcript is classified.
    var intentResult: IntentResult?
    /// Extracted slot parameters when a multi-turn intent is fulfilled (e.g. REMINDER → name, date-time).
    var slots: [String: String]?
    /// Per-stage debug breakdown for the eye-button detail panel.
    var classificationBreakdown: ClassificationBreakdown?

    init(
        id: UUID = UUID(),
        text: String,
        isFinal: Bool,
        locale: Locale,
        timestamp: Date = Date(),
        audioDuration: TimeInterval? = nil,
        confidence: Float? = nil,
        intentResult: IntentResult? = nil,
        slots: [String: String]? = nil
    ) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
        self.locale = locale
        self.timestamp = timestamp
        self.audioDuration = audioDuration
        self.confidence = confidence
        self.intentResult = intentResult
        self.slots = slots
    }
}
