// AudioInputState.swift
// STT
//
// Represents the lifecycle states of an audio input provider.

import Foundation

/// Lifecycle states for any `AudioInputProvider` implementation.
enum AudioInputState: Sendable {
    case idle
    case preparing
    case active
    case stopped
    case failed(Error)
}

extension AudioInputState: Equatable {
    static func == (lhs: AudioInputState, rhs: AudioInputState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.preparing, .preparing), (.active, .active), (.stopped, .stopped):
            return true
        case (.failed, .failed):
            return true
        default:
            return false
        }
    }
}
