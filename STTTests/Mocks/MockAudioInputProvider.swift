// MockAudioInputProvider.swift
// STTTests

import AVFoundation
import Speech
@testable import STT

/// Test double for `AudioInputProvider` that yields controlled buffers.
final class MockAudioInputProvider: AudioInputProvider, @unchecked Sendable {

    // MARK: - Configuration

    /// Buffers to yield when `start()` is called, in order.
    var buffersToYield: [AnalyzerInput] = []
    /// If set, thrown from `audioFormat`.
    var audioFormatError: Error?
    /// If set, signals the stream finished after yielding all buffers.
    var finishesAfterBuffers: Bool = true

    // MARK: - Captured Calls

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    // MARK: - AudioInputProvider

    var audioFormat: AVAudioFormat {
        get async throws {
            if let error = audioFormatError { throw error }
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        }
    }

    private(set) var state: AudioInputState = .idle

    func start() -> AsyncStream<AnalyzerInput> {
        startCallCount += 1
        state = .active
        let buffers = buffersToYield
        let shouldFinish = finishesAfterBuffers
        return AsyncStream { continuation in
            for buffer in buffers {
                continuation.yield(buffer)
            }
            if shouldFinish {
                continuation.finish()
            }
        }
    }

    func stop() {
        stopCallCount += 1
        state = .stopped
    }
}
