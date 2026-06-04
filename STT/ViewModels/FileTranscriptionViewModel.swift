// FileTranscriptionViewModel.swift
// STT

import AVFoundation
import SwiftUI
import os.log

/// Metadata extracted from a selected audio file.
public struct AudioFileInfo: Sendable {
    public let name: String
    public let duration: TimeInterval
    public let format: String
    public let fileSizeBytes: Int64
}

/// View model for the audio file transcription screen.
@Observable
@MainActor
public final class FileTranscriptionViewModel {

    // MARK: - Published State

    public private(set) var selectedFileURL: URL?
    public private(set) var fileInfo: AudioFileInfo?
    public private(set) var transcript: String = ""
    public private(set) var isProcessing: Bool = false
    public private(set) var progress: Double = 0.0
    public private(set) var error: TranscriptionError?
    public private(set) var processingDuration: TimeInterval?

    // MARK: - Private

    private let coordinator: TranscriptionCoordinator
    private var transcriptionTask: Task<Void, Never>?
    private var isSecurityScoped = false
    private let logger = Logger(subsystem: "com.stt.module", category: "FileTranscriptionViewModel")

    private func releaseSecurityScope() {
        if isSecurityScoped, let url = selectedFileURL {
            url.stopAccessingSecurityScopedResource()
            isSecurityScoped = false
        }
    }

    // MARK: - Init

    public init(coordinator: TranscriptionCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Public API

    /// Called when the user selects a file via `fileImporter`.
    ///
    /// Takes ownership of the security-scoped resource for files outside the app
    /// sandbox (iCloud/Files). Access is held until `reset()` or deinit, because
    /// transcription happens later when the user taps "Transcribe".
    public func selectFile(_ url: URL) {
        releaseSecurityScope()
        isSecurityScoped = url.startAccessingSecurityScopedResource()

        selectedFileURL = url
        transcript = ""
        error = nil
        progress = 0.0
        processingDuration = nil
        fileInfo = extractFileInfo(from: url)
    }

    /// Begins transcribing the selected file.
    public func startTranscription() {
        guard let url = selectedFileURL, !isProcessing else { return }
        isProcessing = true
        progress = 0.0
        let startTime = Date()

        transcriptionTask = Task {
            do {
                let result = try await coordinator.transcribeFile(at: url) { [weak self] fraction in
                    self?.progress = fraction
                }
                transcript = result
                processingDuration = Date().timeIntervalSince(startTime)
                progress = 1.0
                logger.info("File transcription complete in \(Date().timeIntervalSince(startTime))s")
            } catch let err as TranscriptionError {
                self.error = err
            } catch {
                self.error = .analyzerFailed(error)
            }
            isProcessing = false
        }
    }

    /// Cancels an in-progress transcription.
    public func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        coordinator.cancelFileTranscription()
        isProcessing = false
        progress = 0.0
        logger.info("File transcription cancelled.")
    }

    /// Resets to the initial state so the user can pick a new file.
    public func reset() {
        releaseSecurityScope()
        selectedFileURL = nil
        fileInfo = nil
        transcript = ""
        error = nil
        progress = 0.0
        processingDuration = nil
    }

    deinit {
        if isSecurityScoped {
            selectedFileURL?.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Private

    private func extractFileInfo(from url: URL) -> AudioFileInfo? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attrs?[.size] as? Int64 ?? 0
        let duration = Double(file.length) / file.fileFormat.sampleRate

        return AudioFileInfo(
            name: url.lastPathComponent,
            duration: duration,
            format: file.fileFormat.description,
            fileSizeBytes: fileSize
        )
    }
}
