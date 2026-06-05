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
public final class FileTranscriptionViewModel: NSObject {

    // MARK: - Transcription State

    public private(set) var selectedFileURL: URL?
    public private(set) var fileInfo: AudioFileInfo?
    public private(set) var transcript: String = ""
    public private(set) var isProcessing: Bool = false
    public private(set) var progress: Double = 0.0
    public private(set) var error: TranscriptionError?
    public private(set) var processingDuration: TimeInterval?

    // MARK: - Playback State

    public private(set) var isPlaying: Bool = false
    /// Current playback position in seconds.
    public private(set) var playbackTime: TimeInterval = 0
    /// 0–1 fraction of playback position; settable for scrubbing.
    public var playbackProgress: Double {
        get {
            guard let duration = fileInfo?.duration, duration > 0 else { return 0 }
            return playbackTime / duration
        }
        set {
            guard let duration = fileInfo?.duration, duration > 0 else { return }
            seek(to: newValue * duration)
        }
    }

    // MARK: - Private

    private let coordinator: TranscriptionCoordinator
    private var transcriptionTask: Task<Void, Never>?
    /// The currently security-scoped URL, if any. Stored separately (and nonisolated)
    /// so `deinit` — which runs in a nonisolated context — can release it without
    /// touching main-actor-isolated state.
    private nonisolated(unsafe) var scopedURL: URL?
    private let logger = Logger(subsystem: "com.stt.module", category: "FileTranscriptionViewModel")

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?

    private func releaseSecurityScope() {
        if let url = scopedURL {
            url.stopAccessingSecurityScopedResource()
            scopedURL = nil
        }
    }

    // MARK: - Init

    public init(coordinator: TranscriptionCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - File Selection

    /// Called when the user selects a file via `fileImporter`.
    ///
    /// Takes ownership of the security-scoped resource for files outside the app
    /// sandbox (iCloud/Files). Access is held until `reset()` or deinit, because
    /// transcription happens later when the user taps "Transcribe".
    public func selectFile(_ url: URL) {
        stopPlayback()
        releaseSecurityScope()
        if url.startAccessingSecurityScopedResource() {
            scopedURL = url
        }

        selectedFileURL = url
        transcript = ""
        error = nil
        progress = 0.0
        processingDuration = nil
        fileInfo = extractFileInfo(from: url)
        preparePlayer(for: url)
    }

    // MARK: - Transcription

    /// Begins transcribing the selected file.
    public func startTranscription() {
        guard let url = selectedFileURL, !isProcessing else { return }
        stopPlayback()
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
        stopPlayback()
        audioPlayer = nil
        releaseSecurityScope()
        selectedFileURL = nil
        fileInfo = nil
        transcript = ""
        error = nil
        progress = 0.0
        processingDuration = nil
        playbackTime = 0
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Playback

    /// Toggles play / pause.
    public func togglePlayback() {
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.pause()
            stopProgressTimer()
            isPlaying = false
        } else {
            player.play()
            startProgressTimer()
            isPlaying = true
        }
    }

    /// Seeks to an absolute time (seconds).
    public func seek(to time: TimeInterval) {
        guard let player = audioPlayer, let duration = fileInfo?.duration else { return }
        let clamped = min(max(time, 0), duration)
        player.currentTime = clamped
        playbackTime = clamped
    }

    // MARK: - Private — Playback helpers

    private func preparePlayer(for url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            audioPlayer = player
            playbackTime = 0
            isPlaying = false
        } catch {
            logger.warning("AVAudioPlayer could not load file: \(error)")
            audioPlayer = nil
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        stopProgressTimer()
        isPlaying = false
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.audioPlayer else { return }
                self.playbackTime = player.currentTime
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - Private — File info

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

// MARK: - AVAudioPlayerDelegate

extension FileTranscriptionViewModel: AVAudioPlayerDelegate {
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stopProgressTimer()
            self.isPlaying = false
            self.playbackTime = 0
            self.audioPlayer?.currentTime = 0
        }
    }
}
