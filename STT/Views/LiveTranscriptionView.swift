// LiveTranscriptionView.swift
// STT

import SwiftUI

/// Hero screen for real-time microphone transcription.
struct LiveTranscriptionView: View {
    @State private var viewModel: LiveTranscriptionViewModel
    @State private var showLanguagePicker = false
    @State private var transcriptOpacity = 1.0

    init(coordinator: TranscriptionCoordinator) {
        _viewModel = State(initialValue: LiveTranscriptionViewModel(coordinator: coordinator))
    }

    var body: some View {
        ZStack(alignment: .top) {
            background

            VStack(spacing: 0) {
                audioSourceBadge
                    .padding(.top, 16)

                transcriptArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                visualizerSection
                    .padding(.bottom, 20)

                autoStopToggle
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)

                micButton
                    .padding(.bottom, viewModel.pendingQuestion == nil ? 32 : 16)

                if let question = viewModel.pendingQuestion {
                    followUpBanner(question)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !viewModel.results.isEmpty {
                    resultsList
                        .frame(maxHeight: 240)
                }
            }
        }
        .onAppear { viewModel.activate() }
        .sheet(isPresented: $showLanguagePicker) {
            LanguageSelectorView(currentLocale: viewModel.currentLocale) { identifier in
                viewModel.switchLocale(identifier)
            }
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.clearResults() } }
        )) {
            Button("Open Settings") { openSettings() }
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(viewModel.error?.localizedDescription ?? "")
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

    private var audioSourceBadge: some View {
        StatusBadge(source: viewModel.audioSource, isActive: viewModel.isListening)
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack {
                    Spacer(minLength: 20)
                    if viewModel.transcript.isEmpty && !viewModel.isListening {
                        emptyState
                    } else {
                        Text(viewModel.transcript.isEmpty ? "Listening..." : viewModel.transcript)
                            .font(.system(size: 22, weight: .light, design: .default))
                            .foregroundStyle(viewModel.isListening && viewModel.transcript.isEmpty
                                             ? .white.opacity(0.35)
                                             : .white)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .id("transcript")
                            .animation(.easeInOut(duration: 0.2), value: viewModel.transcript)
                    }
                    Spacer(minLength: 20)
                }
            }
            .onChange(of: viewModel.transcript) { _, _ in
                withAnimation { proxy.scrollTo("transcript", anchor: .bottom) }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !viewModel.transcript.isEmpty {
                copyButton
                    .padding(.top, 8)
                    .padding(.trailing, 16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.12))

            Text("Tap the mic to start listening...")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.white.opacity(0.25))
                .multilineTextAlignment(.center)

            Text("\"Volume up\" · \"Mute\" · \"Set reminder\"")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.15))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = viewModel.transcript
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .accessibilityLabel("Copy transcript to clipboard")
    }

    private var visualizerSection: some View {
        AudioVisualizerView(level: viewModel.audioLevel, isActive: viewModel.isListening)
            .padding(.horizontal, 24)
            .frame(height: 60)
    }

    private var autoStopToggle: some View {
        Toggle(isOn: $viewModel.autoStopOnSilence) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                Text("Auto-stop on silence")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .tint(Color(red: 0.2, green: 0.6, blue: 1.0))
        .disabled(viewModel.isListening)
        .accessibilityHint("Automatically ends listening shortly after you stop speaking")
    }

    private var micButton: some View {
        PulsingMicButton(
            isListening: viewModel.isListening,
            isProcessing: viewModel.transcriptionState == .preparingAudio
        ) {
            viewModel.toggleRecording()
        }
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Results")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Button("Clear All") {
                    withAnimation(.spring(duration: 0.3)) {
                        viewModel.clearResults()
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 1.0))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.results.reversed()) { result in
                        TranscriptionResultCard(result: result)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Follow-up question banner

    /// Surfaces the NLU engine's follow-up question (e.g. "When should I remind you?")
    /// and nudges the user to answer by speaking again.
    private func followUpBanner(_ question: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 1.0))

            VStack(alignment: .leading, spacing: 2) {
                Text(question)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(viewModel.isListening ? "Listening for your answer…" : "Tap the mic and answer")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0.35), lineWidth: 0.5)
        )
        .animation(.spring(duration: 0.35), value: viewModel.pendingQuestion)
    }

    // MARK: - Helpers

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    LiveTranscriptionView(coordinator: TranscriptionCoordinator())
        .preferredColorScheme(.dark)
}
