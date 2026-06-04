// FileCaptureService.swift
// STT
//
// Single responsibility: reading audio files and converting them to AnalyzerInput streams.

import AVFoundation
import Speech
import os.log

/// Reads an audio file from disk and streams its content as `AnalyzerInput` buffers.
///
/// Supports m4a, wav, mp3, and caf. Converts to the recognizer's preferred format
/// automatically using `AVAudioConverter`.
public final class FileCaptureService: AudioInputProvider, @unchecked Sendable {

    // MARK: - AudioInputProvider

    public var audioFormat: AVAudioFormat {
        get async throws {
            try resolveOutputFormat()
        }
    }

    public private(set) var state: AudioInputState = .idle

    // MARK: - Private

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.stt.module", category: "FileCaptureService")
    private var isCancelled = false
    private let readBufferSize: AVAudioFrameCount = 8192

    // MARK: - Init

    /// - Parameter fileURL: Path to the audio file to transcribe.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - AudioInputProvider

    /// Opens the file and begins streaming converted buffers.
    ///
    /// - Returns: An `AsyncStream` that yields buffers until EOF or `stop()` is called.
    public func start() -> AsyncStream<AnalyzerInput> {
        isCancelled = false
        state = .preparing

        return AsyncStream<AnalyzerInput> { [weak self] continuation in
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

    /// Signals the file reader to stop yielding buffers and finish the stream.
    public func stop() {
        isCancelled = true
        state = .stopped
        logger.info("FileCaptureService cancelled.")
    }

    // MARK: - Private

    private func resolveOutputFormat() throws -> AVAudioFormat {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TranscriptionError.fileNotFound(fileURL)
        }
        let file = try AVAudioFile(forReading: fileURL)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.fileFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionError.unsupportedAudioFormat(file.fileFormat.description)
        }
        return format
    }

    private func streamFile(continuation: AsyncStream<AnalyzerInput>.Continuation) async {
        defer { continuation.finish() }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.error("File not found: \(self.fileURL.path)")
            state = .failed(TranscriptionError.fileNotFound(fileURL))
            return
        }

        do {
            let file = try AVAudioFile(forReading: fileURL)
            guard let outputFormat = try? resolveOutputFormat() else {
                state = .failed(TranscriptionError.unsupportedAudioFormat(file.fileFormat.description))
                return
            }

            let needsConversion = file.processingFormat != outputFormat
            let converter: AVAudioConverter?
            if needsConversion {
                guard let conv = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
                    state = .failed(TranscriptionError.unsupportedAudioFormat(file.processingFormat.description))
                    return
                }
                converter = conv
            } else {
                converter = nil
            }

            state = .active

            while file.framePosition < file.length && !isCancelled {
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: readBufferSize
                ) else { break }

                do { try file.read(into: inputBuffer) } catch { break }

                let outputBuffer: AVAudioPCMBuffer
                if let conv = converter {
                    guard let converted = AVAudioPCMBuffer(
                        pcmFormat: outputFormat,
                        frameCapacity: AVAudioFrameCount(
                            Double(inputBuffer.frameLength)
                                * outputFormat.sampleRate / file.processingFormat.sampleRate
                        ) + 1
                    ) else { break }

                    var conversionError: NSError?
                    let status = conv.convert(to: converted, error: &conversionError) { _, outStatus in
                        outStatus.pointee = .haveData
                        return inputBuffer
                    }
                    if status == .error || conversionError != nil { break }
                    outputBuffer = converted
                } else {
                    outputBuffer = inputBuffer
                }

                continuation.yield(outputBuffer.analyzerInput())
            }

            state = isCancelled ? .stopped : .idle
            logger.info("FileCaptureService finished streaming.")
        } catch {
            logger.error("FileCaptureService failed: \(error)")
            state = .failed(error)
        }
    }
}
