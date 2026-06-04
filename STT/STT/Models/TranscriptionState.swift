// TranscriptionState.swift
// STT
//
// Observable state machine for the transcription pipeline.

import Foundation

/// Represents the current state of the transcription coordinator.
public enum TranscriptionState: Sendable, Equatable {
    case idle
    case requestingPermissions
    case preparingAudio
    case transcribing
    case processingFile(progress: Double)
    case stopping
    case failed(TranscriptionError)

    public static func == (lhs: TranscriptionState, rhs: TranscriptionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.requestingPermissions, .requestingPermissions),
             (.preparingAudio, .preparingAudio),
             (.transcribing, .transcribing),
             (.stopping, .stopping):
            return true
        case (.processingFile(let a), .processingFile(let b)):
            return a == b
        case (.failed, .failed):
            return true
        default:
            return false
        }
    }

    /// Whether the coordinator is actively producing transcription output.
    public var isActive: Bool {
        switch self {
        case .transcribing, .processingFile:
            return true
        default:
            return false
        }
    }
}
