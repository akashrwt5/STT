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
import VoiceIntentSeedPackEN

/// Finds the pack for a language: seeded, already downloaded, or download it.
///
/// This is the host half of the contract. VoiceIntentKit ships no data and does
/// no networking; it asks for a local URL and verifies whatever it is handed.
/// Three places to look, in order:
///
///   1. a linked seed library — SwiftPM copies it into the app at build time,
///      so a fresh install works offline with no Xcode file wrangling
///   2. Application Support — a pack downloaded on an earlier run
///   3. the network — download it now
///
/// The caller cannot tell these apart, which is the point. `packURL` is `async`,
/// so step 3 simply takes longer: the session sits in `.preparing` and the UI
/// says so. No fallback to another language, ever — a wrong-language model
/// produces confident wrong actions, and this is a hearing aid.
struct PackProviderForApp: PackProvider {

    /// Seed packs linked into this app, by language.
    ///
    /// One entry per `VoiceIntentSeedPack*` library the target links. Nothing is
    /// dragged into Xcode: SwiftPM copies the pack into a resource bundle and
    /// Xcode embeds it in the `.app`. Ticking the library IS the integration.
    private static let seeds: [String: () -> URL?] = [
        VoiceIntentSeedPackEN.language: { VoiceIntentSeedPackEN.url },
    ]

    private static func shipsBundledPack(for language: String) -> Bool {
        seeds[language] != nil
    }

    func packURL(for language: String) async throws -> URL {
        // Two SEPARATE questions, deliberately not one `if let` chain:
        //   · do we claim to ship this language?
        //   · is it actually in the bundle?
        //
        // Collapsing them means a pack that is declared but missing falls
        // through to the download branch, which then reports "no pack for 'en'"
        // while listing 'en' as available. That is a real error message this
        // file produced, and it sent the reader looking for a language problem
        // when the cause was a missing folder reference in Xcode.
        if let seed = Self.seeds[language] {
            guard let url = seed() else {
                throw VoiceIntentError.unreadableFile(
                    path: "VoiceIntentSeedPack\(language.uppercased())",
                    reason: """
                        the seed library is linked but its resource bundle has no pack. \
                        Check that the STT target links the VoiceIntentSeedPack\
                        \(language.uppercased()) library (Target → General → Frameworks, \
                        Libraries, and Embedded Content)
                        """)
            }
            return url
        }
        if let cached = Self.downloadedURL(for: language) {
            return cached
        }
        return try await download(language)
    }

    // MARK: - Downloaded packs

    private static var packsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("VoicePacks", isDirectory: true)
    }

    private static func downloadedURL(for language: String) -> URL? {
        let dir = packsDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        // `pack-<lang>-v<version>` — newest wins if several are present.
        guard let newest = names.filter({ $0.hasPrefix("pack-\(language)-") }).sorted().last else {
            return nil
        }
        return dir.appendingPathComponent(newest, isDirectory: true)
    }

    /// Fetch, unpack and return a local URL.
    ///
    /// Not built yet — the catalog endpoint and signing-key distribution are
    /// still open (compiler asks A2/B6c). Throwing a specific error is the
    /// honest placeholder: the session refuses, the UI says the language is not
    /// ready, and nothing runs in a language the user did not ask for.
    private func download(_ language: String) async throws -> URL {
        throw VoiceIntentError.languageUnavailable(
            requested: language,
            available: Self.seeds.keys.sorted())
    }
}

/// The user's language comes from the device. No mapping table, no fallback.
///
/// `Locale.current` already carries both halves the session needs: the language
/// code for the pack ("fr") and the full identifier for the speech recogniser
/// ("fr-FR"). Deriving one from the other with a hand-maintained table would be
/// 23 entries of application code at full language coverage, and wrong for the
/// cases that matter — "en" is en-US or en-GB depending on the user, not on a
/// lookup. The device already knows.
struct PackageVoiceView: View {

    /// Override for testing another language. Nil = use the device's.
    private static let languageOverride: String? = nil

    private static var deviceLanguage: VoiceLanguage {
        let locale = Locale.current
        let code = languageOverride
            ?? locale.language.languageCode?.identifier
            ?? "en"
        return code == "en"
            ? .english
            : .language(code: code, locale: locale.identifier)
    }

    var body: some View {
        PackageVoiceSessionView(language: Self.deviceLanguage,
                                provider: PackProviderForApp())
    }
}

/// The session UI.
private struct PackageVoiceSessionView: View {
    @Environment(\.dismiss) private var dismiss

    // Single-utterance mode (default): after each turn the session returns to
    // `.idle`. Flip `autoStopOnSilence: false` for continuous listening across
    // multiple turns without re-tapping Start.
    @State private var session: VoiceIntentSession

    init(language: VoiceLanguage, provider: PackProviderForApp) {
        _session = State(wrappedValue: VoiceIntentSession(configuration: .init(
            language: language,
            packProvider: provider,
            // Dev-signed pack, dev build. A release build must supply the
            // production public key and refuse dev-signed packs (ADR-005 Part 11).
            trust: .unverifiedForTesting,
            autoStopOnSilence: true)))
    }

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
                            // NOT `try?`. The session now refuses to start on a
                            // missing, unsigned or wrong-language pack, and
                            // discarding that error reproduces exactly the failure
                            // this refactor exists to remove: everything looks fine
                            // and nothing works. Show it.
                            do {
                                try await session.start()
                            } catch {
                                listening = false
                                status = "Failed to start"
                                lastTurn = "⚠️ \(error)"
                            }
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
