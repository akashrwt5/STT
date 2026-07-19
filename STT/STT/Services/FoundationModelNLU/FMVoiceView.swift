// FMVoiceView.swift
// STT — FoundationModelNLU (evaluation sample; see docs/FM_SAMPLE_PLAN.md)
//
// The fourth landing-screen option. Hosts the EXISTING LiveTranscriptionView
// (full conversation UI, slot filling, TTS) on top of the FM classifier, plus:
//   - an always-visible "FM" origin badge with per-turn latency, so an
//     evaluator can never confuse this screen with the cascade paths;
//   - a DEBUG-only benchmark row (plan §8) that runs the bundled 341-utterance
//     holdout and shares the report as CSV.
//
// The #else branch renders a "not supported" placeholder so this file always
// compiles — same pattern as PackageVoiceView.

import SwiftUI

#if canImport(FoundationModels)

@available(iOS 26.0, *)
struct FMVoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = FMVoiceViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                originBadge
                #if DEBUG
                benchmarkRow
                #endif
                LiveTranscriptionView(viewModel: viewModel.liveViewModel)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { closeButton }
                ToolbarItem(placement: .principal) {
                    Text("Foundation Model PVA")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .toolbarBackground(.clear, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onAppear { viewModel.startSession() }
        .onDisappear { viewModel.teardown() }
    }

    // MARK: - Origin badge

    private var originBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "apple.intelligence")
                .font(.caption2)
            Text(badgeText)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.purple.opacity(0.15), in: Capsule())
        .padding(.top, 8)
    }

    private var badgeText: String {
        var parts = ["via Apple Foundation Model · on-device"]
        if !viewModel.engineReady { parts.append("warming up…") }
        if let last = FMMetrics.latest, !last.failed {
            parts.append(String(format: "last turn %.0fms", last.latencyMS))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Benchmark row (DEBUG)

    #if DEBUG
    @ViewBuilder
    private var benchmarkRow: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.runBenchmark()
            } label: {
                Label(
                    viewModel.benchmarkRunning
                        ? "Benchmark \(viewModel.benchmarkProgress.done)/\(viewModel.benchmarkProgress.total)"
                        : "Run Holdout Benchmark",
                    systemImage: "gauge.with.needle"
                )
                .font(.caption)
            }
            .disabled(viewModel.benchmarkRunning)

            if let report = viewModel.benchmarkReport {
                Text(String(format: "%.1f%% (base 89.4%%)", report.accuracy * 100))
                    .font(.caption.bold())
                    .foregroundStyle(report.accuracy >= FMBenchmarkReport.overallBar ? .green : .orange)
                ShareLink(item: report.csvText,
                          preview: SharePreview("FM Benchmark Report")) {
                    Image(systemName: "square.and.arrow.up").font(.caption)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
    #endif

    // MARK: - Toolbar

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
        .accessibilityLabel("Close Foundation Model session")
    }
}

#else

/// Placeholder when the FoundationModels framework isn't available at compile
/// time (SDK < iOS 26). Mirrors PackageVoiceView's pattern so the landing
/// screen compiles unconditionally.
struct FMVoiceView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "apple.intelligence").font(.largeTitle).foregroundStyle(.secondary)
                Text("Foundation Models unavailable").font(.headline)
                Text("Building this mode requires the iOS 26 SDK with the FoundationModels framework.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
    }
}

#endif
