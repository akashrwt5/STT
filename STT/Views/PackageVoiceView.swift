// PackageVoiceView.swift
// STT
//
// The third landing-screen option. When the user picks "Package" on
// STTTestView, this sheet drives the entire session through
// VoiceIntentKit's public facade (VoiceIntentSession) — no app-side NLU
// wiring. English and Multilingual stay on the in-project pipeline.
//
// #if canImport keeps this file compiling before the local package is
// added to the STT target (that's a one-time Xcode GUI step, per
// VoiceIntentKit/INTEGRATION.md — Step 1). After adding the package
// dependency, this view activates automatically.

import SwiftUI

#if canImport(VoiceIntentKit)
import VoiceIntentKit

struct PackageVoiceView: View {
    @Environment(\.dismiss) private var dismiss
    // Single-utterance mode (default): after each turn the session returns to
    // `.idle`. Flip `autoStopOnSilence: false` for continuous listening across
    // multiple turns without re-tapping Start.
    @State private var session = VoiceIntentSession(
        configuration: .init(language: .english, autoStopOnSilence: true)
    )
    @State private var transcript = ""
    @State private var status = "Idle"
    @State private var lastTurn = ""
    @State private var listening = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Visible origin badge: this screen is served by the
                // VoiceIntentKit package (log subsystem `com.voiceintentkit`).
                // Filter Console.app by that subsystem to see only these logs
                // — the app's English/Multilingual paths use a different one.
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox.fill").font(.caption2)
                    Text("via VoiceIntentKit · logs: com.voiceintentkit")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.blue.opacity(0.12), in: Capsule())

                Text(status).font(.footnote).foregroundStyle(.secondary)
                Text(transcript.isEmpty ? "Say something…" : transcript)
                    .font(.title3).multilineTextAlignment(.center)
                if !lastTurn.isEmpty {
                    Text(lastTurn).font(.callout)
                        .padding().background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
                Button(listening ? "Stop" : "Start (via Package)") {
                    Task {
                        if listening { session.stop(); listening = false }
                        else {
                            transcript = ""            // clear the previous turn's text
                            listening = true
                            try? await session.start()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Package PVA")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { session.stop(); dismiss() } } }
        }
        .task {
            for await event in session.events {
                switch event {
                case .partialTranscript(let t), .finalTranscript(let t):
                    transcript = t
                case .stateChanged(let s):
                    status = "\(s)"
                    // Button reflects "is the mic actually live?". `.listening`
                    // is the only state where the mic is capturing user audio;
                    // everything else means "not listening right now" — stopped,
                    // idle after a turn, mid-classification, or speaking a prompt.
                    listening = (s == .listening)
                case .error(let m):
                    lastTurn = "Error: \(m)"
                    listening = false
                case .turn(let turn):
                    lastTurn = describe(turn)
                }
            }
        }
    }

    private func describe(_ t: VoiceIntentTurn) -> String {
        switch t {
        case .followUp(let q, _):
            return "❓ \(q)"
        case .confirmation(let q):
            return "✅? \(q)"
        case .fulfilled(let i, let s, _, let c, let rescue, let stages):
            let slotsStr = s.isEmpty ? "" : " \(s)"
            return "🎯 \(i)\(slotsStr) (\(pct(c)))\n\(stageLine(stages, rescue: rescue))"
        case .notUnderstood(_, let c, let stages):
            return "🤷 not understood (\(pct(c)))\n\(stageLine(stages, rescue: false))"
        case .interrupted(let cancelled):
            return "↩︎ cancelled \(cancelled)"
        }
    }

    /// One-line summary of which of the 3 stages produced the answer, plus the
    /// scores of each stage that ran. Mirrors what the app's English /
    /// Multilingual debug view shows.
    private func stageLine(_ s: VoiceIntentStages?, rescue: Bool) -> String {
        guard let s else { return "stage: —" }
        let winner: String
        switch s.winningStage {
        case 1: winner = "S1 keyword"
        case 2: winner = "S2 TF-IDF/CoreML"
        case 3: winner = "S3 MiniLM rescue"
        default: winner = "GenAI fallback"
        }
        var parts: [String] = ["stage: \(winner)"]
        if let s2 = s.stage2Score { parts.append("S2=\(pct(s2))") }
        if let s3 = s.stage3Score { parts.append("S3=\(pct(s3))") }
        if rescue { parts.append("(rescued)") }
        return parts.joined(separator: "  ")
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}
#else
/// Placeholder shown until the VoiceIntentKit local package is added to the
/// STT target (Xcode → File → Add Package Dependencies… → Add Local… → point
/// at ./VoiceIntentKit). See VoiceIntentKit/INTEGRATION.md.
struct PackageVoiceView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.secondary)
                Text("VoiceIntentKit not linked").font(.headline)
                Text("Add the local VoiceIntentKit package to the STT target — see VoiceIntentKit/INTEGRATION.md.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
    }
}
#endif
