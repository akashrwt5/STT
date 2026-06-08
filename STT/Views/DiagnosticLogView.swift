// DiagnosticLogView.swift
// STT
//
// Debug-only screen for exporting the com.stt.module os_log stream.
// Reached via the ⚙ → "Export Diagnostic Logs" button in STTTestView.
// Has no effect on the transcription pipeline — purely observational.

import SwiftUI

struct DiagnosticLogView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var logText: String = ""
    @State private var exportURL: URL?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var windowMinutes: Int = 15

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.08).ignoresSafeArea()

                VStack(spacing: 0) {
                    controlBar
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    Divider()
                        .background(.white.opacity(0.1))

                    if isLoading {
                        Spacer()
                        ProgressView("Fetching logs…")
                            .tint(.white)
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                    } else if let error = errorMessage {
                        Spacer()
                        errorBanner(error)
                            .padding(.horizontal, 24)
                        Spacer()
                    } else if logText.isEmpty {
                        emptyState
                    } else {
                        logScrollView
                    }
                }
            }
            .navigationTitle("Diagnostic Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(
                Color(red: 0.04, green: 0.04, blue: 0.08),
                for: .navigationBar
            )
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
                ToolbarItem(placement: .primaryAction) {
                    if let url = exportURL {
                        ShareLink(item: url, subject: Text("STT Diagnostic Logs")) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 1.0))
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var controlBar: some View {
        HStack(spacing: 12) {
            // Window picker
            Menu {
                ForEach([5, 15, 30, 60], id: \.self) { mins in
                    Button("Last \(mins) min") { windowMinutes = mins }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                    Text("Last \(windowMinutes) min")
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("Select log time window")

            Spacer()

            Button {
                Task { await fetchLogs() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Fetch")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.2, green: 0.6, blue: 1.0),
                                 Color(red: 0.1, green: 0.35, blue: 0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
            .disabled(isLoading)
            .accessibilityLabel("Fetch diagnostic logs")
        }
    }

    private var logScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(logText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
                    .id("logBottom")
            }
            .onAppear {
                // Scroll to end so the most recent entries are visible first.
                withAnimation { proxy.scrollTo("logBottom", anchor: .bottom) }
            }
            // DIAG markers highlighted via background: not easily done in Text
            // without attributed strings — plain monospaced is good enough for triage.
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.12))
            Text("Tap Fetch to load the com.stt.module\nlog entries for the selected window.")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: - Actions

    private func fetchLogs() async {
        isLoading = true
        errorMessage = nil
        logText = ""
        exportURL = nil

        do {
            let url = try await DiagnosticLogExporter.shared.export(windowMinutes: windowMinutes)
            let text = try String(contentsOf: url, encoding: .utf8)
            logText = text
            exportURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    DiagnosticLogView()
}
