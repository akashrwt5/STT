// PVASheetView.swift
// STT
//
// Full-screen sheet hosting an onDevice PVA session.
// Adds a stage pipeline status bar to the navigation toolbar and delegates
// all transcription UI to LiveTranscriptionView.

import SwiftUI

struct PVASheetView: View {
    let viewModel: PVAViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: PVAViewModel) {
        self.viewModel = viewModel
        // Bisects the tap → onAppear window: if this logs early but onAppear is
        // late, the stall is in presentation/first render, not view construction.
        PVALaunchClock.mark("sheet view constructed")
    }

    var body: some View {
        NavigationStack {
            LiveTranscriptionView(viewModel: viewModel.liveViewModel)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        closeButton
                    }
                    ToolbarItem(placement: .principal) {
                        stagePipelineBar
                    }
                }
                .toolbarBackground(.clear, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onAppear {
            // The tap → here gap is the presentation cost the user actually feels.
            PVALaunchClock.mark("sheet appeared")
            viewModel.startSession()
        }
        .onDisappear {
            viewModel.teardown()
        }
    }

    // MARK: - Toolbar items

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.12), in: Circle())
        }
        .accessibilityLabel("Close PVA session")
    }

    /// S1 → S2 → S3 chips with live readiness dots.
    private var stagePipelineBar: some View {
        HStack(spacing: 6) {
            stageChip(label: "S1", status: viewModel.stage1Status)
            connectorChevron
            stageChip(label: "S2", status: viewModel.stage2Status)
            connectorChevron
            stageChip(label: "S3", status: viewModel.stage3Status)
        }
    }

    private var connectorChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white.opacity(0.2))
    }

    private func stageChip(label: String, status: StageReadiness) -> some View {
        HStack(spacing: 5) {
            StageStatusDot(status: status)
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(status == .ready ? .white.opacity(0.9) : .white.opacity(0.35))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status == .ready ? .white.opacity(0.10) : .white.opacity(0.05),
                    in: Capsule())
        .animation(.easeInOut(duration: 0.4), value: status)
    }
}

// MARK: - Stage status dot

/// Animated dot reflecting a pipeline stage's readiness state.
private struct StageStatusDot: View {
    let status: StageReadiness
    @State private var pulsing = false

    var body: some View {
        ZStack {
            // Expanding ring — only shown while loading.
            if status == .loading {
                Circle()
                    .fill(dotColor.opacity(0.3))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulsing ? 1.9 : 1.0)
                    .opacity(pulsing ? 0.0 : 0.6)
            }
            // Core dot — always shown.
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard status == .loading else { return }
            withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
        .onChange(of: status) { _, _ in
            // Stop the animation when stage becomes ready or fails.
            pulsing = false
        }
    }

    private var dotColor: Color {
        switch status {
        case .loading: return Color(red: 1.0, green: 0.65, blue: 0.1)  // amber
        case .ready:   return Color(red: 0.2, green: 0.85, blue: 0.5)  // green
        case .failed:  return .red
        }
    }
}

#Preview {
    PVASheetView(viewModel: PVAViewModel(variant: .english))
        .preferredColorScheme(.dark)
}
