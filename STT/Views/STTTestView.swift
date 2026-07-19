// STTTestView.swift
// STT

import SwiftUI

/// Root landing screen.
///
/// Provides a prominent launch point for the onDevice PVA session (full sheet with
/// S1/S2/S3 pipeline) and secondary access to file transcription.
struct STTTestView: View {
    @State private var coordinator = TranscriptionCoordinator()
    @State private var showLanguagePicker = false
    @State private var showFileTranscription = false
    /// Non-nil while a PVA sheet is open. Setting this to nil dismisses the sheet
    /// and triggers full deallocation of the coordinator + NLU pipeline it owns.
    @State private var pvaViewModel: PVAViewModel?
    /// Set when the user picks "Package" — presents the VoiceIntentKit-backed screen.
    @State private var showPackageSession = false
    /// Set when the user picks "FM" — presents the Foundation Models sample screen
    /// (evaluation sample; see docs/FM_SAMPLE_PLAN.md).
    @State private var showFMSession = false
    /// Persisted NLU pipeline selection. NLUVariant.RawValue == String satisfies
    /// AppStorage's RawRepresentable requirement directly, so the choice survives
    /// app restarts with no extra storage glue.
    @AppStorage("selectedNLUVariant") private var variant: NLUVariant = .english
    /// First-screen selection including the package path. English/Multilingual map
    /// to the existing NLUVariant flow; Package routes to VoiceIntentKit.
    @State private var pipeline: PipelineChoice = .english

    enum PipelineChoice: String, CaseIterable, Identifiable {
        case english, multilingual, package, foundationModel
        var id: String { rawValue }
        var title: String {
            switch self {
            case .english:         return "English"
            case .multilingual:    return "Multilingual"
            case .package:         return "Package"
            case .foundationModel: return "FM"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.04, green: 0.04, blue: 0.08).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()
                pvaLauncher
                Spacer()
                fileTranscriptionLink
                    .padding(.bottom, 52)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $pvaViewModel) { vm in
            PVASheetView(viewModel: vm)
        }
        .sheet(isPresented: $showFileTranscription) {
            FileTranscriptionView(coordinator: coordinator)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showLanguagePicker) {
            LanguageSelectorView(currentLocale: coordinator.currentLocale) { identifier in
                Task { try? await coordinator.switchLocale(to: identifier) }
            }
        }
        .sheet(isPresented: $showPackageSession) {
            PackageVoiceView().preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showFMSession) {
            FMVoiceView().preferredColorScheme(.dark)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speech Engine")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 0.2, green: 0.8, blue: 0.5))
                        .frame(width: 6, height: 6)
                    Text(headerSubtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Spacer()

            Button {
                showLanguagePicker = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Open settings and language picker")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var headerSubtitle: String {
        let lang = Locale.current.localizedString(forIdentifier: coordinator.currentLocale.identifier)
            ?? coordinator.currentLocale.identifier
        return "\(lang) · on-device"
    }

    // MARK: - PVA launcher

    private var pvaLauncher: some View {
        VStack(spacing: 28) {

            // Icon cluster
            ZStack {
                Circle()
                    .fill(Color(red: 0.1, green: 0.3, blue: 0.9).opacity(0.18))
                    .frame(width: 96, height: 96)
                Circle()
                    .fill(Color(red: 0.15, green: 0.4, blue: 1.0).opacity(0.10))
                    .frame(width: 70, height: 70)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 38))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.55, green: 0.78, blue: 1.0),
                                Color(red: 0.3,  green: 0.55, blue: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            // Labels
            VStack(spacing: 8) {
                Text("onDevice PVA")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                Text("3-stage on-device intent classification\nKeyword · TF-IDF · MiniLM-L6-v2")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.38))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            // Pipeline selector — persisted across launches for English/Multilingual;
            // Package is a per-launch choice that routes into VoiceIntentKit.
            Picker("Pipeline", selection: $pipeline) {
                ForEach(PipelineChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 32)
            // Full teardown on switch: nil-ing pvaViewModel releases the entire
            // pipeline (PVAViewModel → TranscriptionCoordinator →
            // LiveTranscriptionViewModel → NLUEngine → classifier →
            // SemanticEmbedder) before a new session is constructed, avoiding
            // doubled ANE memory and audio-session conflicts. Verified by the
            // [Deinit] log chain in the Xcode console.
            .onChange(of: pipeline) { _, new in
                if new != .package, pvaViewModel != nil {
                    pvaViewModel?.teardown()
                    pvaViewModel = nil
                }
                if new == .english      { variant = .english }
                if new == .multilingual { variant = .multilingual }
            }

            // FM mode is disabled-with-reason on ineligible hardware rather than
            // hidden — the evaluator should see *why* (docs/FM_SAMPLE_PLAN.md §6).
            if pipeline == .foundationModel && !fmStatus.isAvailable {
                Text(fmStatus.userMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // Primary CTA
            Button {
                PVALaunchClock.tapped()
                if pipeline == .package {
                    showPackageSession = true                      // VoiceIntentKit path
                } else if pipeline == .foundationModel {
                    showFMSession = true                           // FM sample path
                } else {
                    pvaViewModel = PVAViewModel(variant: variant)  // existing in-app path
                }
            } label: {
                Text("Try onDevice PVA")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 264, height: 56)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.25, green: 0.55, blue: 1.0),
                                Color(red: 0.15, green: 0.40, blue: 0.95)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                    .shadow(color: Color(red: 0.2, green: 0.45, blue: 1.0).opacity(0.40),
                            radius: 16, x: 0, y: 6)
            }
            .accessibilityLabel("Start onDevice PVA session")
            .disabled(pipeline == .foundationModel && !fmStatus.isAvailable)
            .opacity(pipeline == .foundationModel && !fmStatus.isAvailable ? 0.4 : 1)
        }
    }

    /// Foundation Model availability, re-checked per render (cheap property read).
    private var fmStatus: FMAvailabilityStatus { FMAvailability.status() }

    // MARK: - File transcription link

    private var fileTranscriptionLink: some View {
        Button {
            showFileTranscription = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 13))
                Text("File Transcription")
                    .font(.system(size: 14, weight: .medium))
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.35))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.white.opacity(0.05), in: Capsule())
        }
        .accessibilityLabel("Open file transcription")
    }
}

#Preview {
    STTTestView()
}
