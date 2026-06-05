// TranscriptionDelegate.swift
// STT
//
// Delegation interface for the transcription pipeline.

import Foundation

/// Permission check result returned by `TranscriptionCoordinator.checkPermissions()`.
public enum PermissionStatus: Sendable {
    case granted
    case microphoneDenied
    case speechRecognitionDenied
    case allDenied
}

/// Callback interface for consumers that prefer delegation over `AsyncSequence`.
///
/// All methods are called on the main actor.
@MainActor
public protocol TranscriptionDelegate: AnyObject {
    /// Called continuously as the recognizer produces in-progress text.
    func didReceivePartialResult(_ text: String)

    /// Called when the recognizer commits a final, stable transcription segment.
    func didReceiveFinalResult(_ text: String)

    /// Called when a non-recoverable error terminates the session.
    func didEncounterError(_ error: TranscriptionError)

    /// Called whenever the coordinator transitions between states.
    func didChangeState(_ state: TranscriptionState)

    /// Called when automatic silence detection ends a live session because the user
    /// stopped speaking (or never spoke). Only fired when silence detection is enabled.
    /// Optional — defaults to a no-op.
    func didReachEndOfSpeech()
}

public extension TranscriptionDelegate {
    /// Default no-op so existing conformers need not implement silence handling.
    func didReachEndOfSpeech() {}
}
