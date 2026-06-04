// MockTranscriptionDelegate.swift
// STTTests

@testable import STT

/// Test double capturing all `TranscriptionDelegate` callbacks.
@MainActor
final class MockTranscriptionDelegate: TranscriptionDelegate {

    private(set) var partialResults: [String] = []
    private(set) var finalResults: [String] = []
    private(set) var errors: [TranscriptionError] = []
    private(set) var states: [TranscriptionState] = []

    func didReceivePartialResult(_ text: String) {
        partialResults.append(text)
    }

    func didReceiveFinalResult(_ text: String) {
        finalResults.append(text)
    }

    func didEncounterError(_ error: TranscriptionError) {
        errors.append(error)
    }

    func didChangeState(_ state: TranscriptionState) {
        states.append(state)
    }
}
