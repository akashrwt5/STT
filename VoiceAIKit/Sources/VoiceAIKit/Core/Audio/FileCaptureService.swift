// FileCaptureService.swift
// STT
//
// Single responsibility: reading audio files and streaming raw buffers.

import AVFoundation
import os.log

/// Reads an audio file from disk and streams its content as raw `AVAudioPCMBuffer`s.
///
/// Supports m4a, wav, mp3, and caf. Format conversion to the analyzer's required
/// format is handled downstream by `SpeechRecognitionService`.
final class FileCaptureService: AudioInputProvider, @unchecked Sendable {

    // MARK: - AudioInputProvider

    var audioFormat: AVAudioFormat {
        get async throws { try resolveProcessingFormat() }
    }

    private(set) var state: AudioInputState = .idle

    /// Real frame-based progress (0.0...1.0), driven as the file is read.
    let progressStream: AsyncStream<Double>?

    // MARK: - Private

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.voiceaikit", category: "FileCaptureService")
    /// Lock-protected so `stop()` (called on the main actor) and `streamFile()`
    /// (running on a background Task.detached) can safely read/write without a race.
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let readBufferSize: AVAudioFrameCount = 8192
    private let progressContinuation: AsyncStream<Double>.Continuation

    // MARK: - Init

    /// - Parameter fileURL: Path to the audio file to transcribe.
    init(fileURL: URL) {
        self.fileURL = fileURL
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        self.progressStream = stream
        self.progressContinuation = continuation
    }

    // MARK: - AudioInputProvider

    /// Opens the file and begins streaming raw buffers.
    func start() -> AsyncStream<AVAudioPCMBuffer> {
        cancelled.withLock { $0 = false }
        state = .preparing
        return AsyncStream<AVAudioPCMBuffer> { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.streamFile(continuation: continuation)
            }
        }
    }

    /// Signals the file reader to stop yielding buffers.
    func stop() {
        cancelled.withLock { $0 = true }
        state = .stopped
        logger.info("FileCaptureService cancelled.")
    }

    // MARK: - Private

    private func resolveProcessingFormat() throws -> AVAudioFormat {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TranscriptionError.fileNotFound(fileURL)
        }
        let file = try AVAudioFile(forReading: fileURL)
        return file.processingFormat
    }

    private func streamFile(continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) async {
        defer {
            continuation.finish()
            progressContinuation.finish()
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.error("File not found: \(self.fileURL.path)")
            state = .failed(TranscriptionError.fileNotFound(fileURL))
            return
        }

        do {
            let file = try AVAudioFile(forReading: fileURL)
            state = .active
            let totalFrames = max(file.length, 1)

            while file.framePosition < file.length && !cancelled.withLock({ $0 }) {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: readBufferSize
                ) else { break }

                do {
                    try file.read(into: buffer)
                } catch {
                    break
                }
                guard buffer.frameLength > 0 else { break }
                continuation.yield(buffer)

                // Report real progress based on how far into the file we've read.
                let progress = Double(file.framePosition) / Double(totalFrames)
                progressContinuation.yield(min(progress, 1.0))
            }

            let wasCancelled = cancelled.withLock { $0 }
            if !wasCancelled { progressContinuation.yield(1.0) }
            state = wasCancelled ? .stopped : .idle
            logger.info("FileCaptureService finished streaming.")
        } catch {
            logger.error("FileCaptureService failed: \(error)")
            state = .failed(error)
        }
    }
}
