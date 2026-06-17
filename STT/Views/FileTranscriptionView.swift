// FileTranscriptionView.swift
// STT

import SwiftUI
import UniformTypeIdentifiers

/// Audio file picker and transcription screen.
struct FileTranscriptionView: View {
    @State private var viewModel: FileTranscriptionViewModel
    @State private var showFilePicker = false

    init(coordinator: TranscriptionCoordinator) {
        _viewModel = State(initialValue: FileTranscriptionViewModel(coordinator: coordinator))
    }

    private let supportedTypes: [UTType] = [.audio, .wav, .mp3, .mpeg4Audio]

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(spacing: 20) {
                    filePickerArea
                        .padding(.top, 16)

                    if let info = viewModel.fileInfo {
                        fileInfoCard(info)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if viewModel.isProcessing {
                        progressSection
                            .transition(.opacity)
                    }

                    if !viewModel.transcript.isEmpty {
                        resultSection
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if let error = viewModel.error {
                        errorBanner(error)
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 16)
                .animation(.spring(duration: 0.35), value: viewModel.fileInfo != nil)
                .animation(.spring(duration: 0.35), value: viewModel.isProcessing)
                .animation(.spring(duration: 0.35), value: !viewModel.transcript.isEmpty)
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            // The view model takes ownership of the security-scoped resource and holds
            // it until transcription is done, so we must NOT start/stop access here.
            if case .success(let urls) = result, let url = urls.first {
                viewModel.selectFile(url)
            }
        }
    }

    // MARK: - Subviews

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.04, blue: 0.08),
                Color(red: 0.02, green: 0.03, blue: 0.06)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var filePickerArea: some View {
        Button { showFilePicker = true } label: {
            VStack(spacing: 16) {
                Image(systemName: viewModel.selectedFileURL == nil ? "waveform.badge.plus" : "waveform.badge.checkmark")
                    .font(.system(size: 40))
                    .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 1.0))
                    .symbolEffect(.pulse, isActive: viewModel.selectedFileURL == nil)

                Text(viewModel.selectedFileURL == nil ? "Select an audio file" : "Tap to change file")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))

                Text("WAV · MP3 · M4A · CAF")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .foregroundStyle(.white.opacity(0.18))
            )
        }
        .accessibilityLabel("Select audio file for transcription")
    }

    private func fileInfoCard(_ info: AudioFileInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // File name + metadata row
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 1.0))

                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        Text(formattedDuration(info.duration))
                        Text("·")
                        Text(formattedFileSize(info.fileSizeBytes))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
            }

            // Playback controls
            playbackControls(duration: info.duration)

            // Transcribe button (hidden while processing)
            if !viewModel.isProcessing {
                Button {
                    viewModel.startTranscription()
                } label: {
                    Text("Transcribe")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.2, green: 0.6, blue: 1.0), Color(red: 0.1, green: 0.35, blue: 0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
                .accessibilityLabel("Start transcription")
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 0.5))
    }

    private func playbackControls(duration: TimeInterval) -> some View {
        VStack(spacing: 8) {
            // Scrubber
            Slider(value: $viewModel.playbackProgress, in: 0...1) { editing in
                // When the user starts dragging, pause; resume when done
                if editing && viewModel.isPlaying {
                    viewModel.togglePlayback()
                }
            }
            .tint(Color(red: 0.2, green: 0.6, blue: 1.0))
            .accessibilityLabel("Playback position")

            // Play / Pause button + time labels
            HStack {
                Text(formattedDuration(viewModel.playbackTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 44, alignment: .leading)

                Spacer()

                Button {
                    viewModel.togglePlayback()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 1.0))
                        .symbolEffect(.bounce, value: viewModel.isPlaying)
                }
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

                Spacer()

                Text("-\(formattedDuration(max(0, duration - viewModel.playbackTime)))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    private var progressSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Transcribing...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button("Cancel") {
                    viewModel.cancel()
                }
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.35))
            }

            ProgressView(value: viewModel.progress)
                .tint(Color(red: 0.2, green: 0.6, blue: 1.0))
                .background(.white.opacity(0.08), in: Capsule())
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                if let duration = viewModel.processingDuration {
                    Text(String(format: "%.1fs", duration))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            Text(viewModel.transcript)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = viewModel.transcript
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                ShareLink(item: viewModel.transcript) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Spacer()

                Button("Transcribe Another") {
                    withAnimation(.spring(duration: 0.3)) { viewModel.reset() }
                }
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 1.0))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 0.5))
    }

    private func errorBanner(_ error: TranscriptionError) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
            Text(error.localizedDescription)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Retry") { viewModel.startTranscription() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 1.0))
        }
        .padding(14)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: - Formatters

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    private func formattedFileSize(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

#Preview {
    FileTranscriptionView(coordinator: TranscriptionCoordinator())
        .preferredColorScheme(.dark)
}
