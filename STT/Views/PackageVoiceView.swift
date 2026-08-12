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

/// Finds the pack for a language: the OTA-activated pack if one exists and verifies,
/// otherwise the bundled seed.
///
/// This is the host half of the contract, and it is where the OTA subsystem and the live
/// `VoiceIntentSession` finally meet. VoiceIntentKit ships no data and does no networking; the
/// `NLUOTAManager` downloads, verifies and atomically publishes a pack to
/// `PackStorageController`'s `Current` symlink, and this provider reads that same location back.
/// Two places to look, in order:
///
///   1. the OTA-activated pack — `PackStorageController.currentPack(for:)`, under the SAME storage
///      base the OTA writer uses (`OTAStorageLocator`). Served only if it passes an integrity
///      pre-check, so a half-written or corrupt `Current` never reaches the session.
///   2. the bundled seed — SwiftPM copies it into the app at build time, so a fresh install (or a
///      failed/absent OTA pack) works offline. Same-language fallback only.
///
/// "Apply on next build": because `VoiceIntentSession.buildEngine()` calls this every time it
/// stands up, an OTA activation is picked up by the very next session with no app restart and no
/// live hot-swap. No fallback to another LANGUAGE, ever — a wrong-language model produces confident
/// wrong actions, and this is a hearing aid.
struct PackProviderForApp: PackProvider {

    /// Seed packs linked into this app, by language.
    ///
    /// One entry per `VoiceIntentSeedPack*` library the target links. Nothing is
    /// dragged into Xcode: SwiftPM copies the pack into a resource bundle and
    /// Xcode embeds it in the `.app`. Ticking the library IS the integration.
    private static let seeds: [String: () -> URL?] = [
        VoiceIntentSeedPackEN.language: { VoiceIntentSeedPackEN.url },
    ]

    /// The trust policy used to gate an OTA pack before serving it. Must match the policy the
    /// session loads with (see `PackageVoiceSessionView`). Dev builds skip signatures; a release
    /// build must supply a production policy with the real key(s).
    /// TODO: (Security / ADR-005 Part 11) replace with the production policy for release builds.
    static let trust: PackTrustPolicy = .unverifiedForTesting

    /// Reads the OTA-activated pack location. Built against the shared `OTAStorageLocator` base so
    /// it resolves the exact directory the OTA writer publishes into.
    private static let otaStorage: PackStorageControlling? = {
        try? PackStorageController(baseStorageURL: OTAStorageLocator.baseStorageURL)
    }()

    func packURL(for language: String) async throws -> URL {
        // 1. OTA-activated pack — the freshest verified pack, if one has been published. Gated by
        //    a full integrity check so a corrupt `Current` falls through to the seed instead of
        //    being handed to the session (which would throw rather than degrade).
        if let current = Self.otaStorage?.currentPack(for: language),
           (try? PackIntegrity.verify(packRoot: current, trust: Self.trust)) != nil {
            return current
        }

        // 2. Bundled seed — same-language floor. Two SEPARATE questions, deliberately not one
        //    `if let` chain: do we claim to ship this language, and is it actually in the bundle?
        //    Collapsing them turns a missing-in-Xcode pack into a misleading "no pack for 'en'".
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

        // 3. Neither an OTA pack nor a seed for this language.
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

    @State private var transcript = ""
    @State private var status = "Idle"
    @State private var lastTurn = ""
    @State private var listening = false
    @State private var packVersion = "Loading..."
    
    private let provider: PackProviderForApp
    private let language: VoiceLanguage

    init(language: VoiceLanguage, provider: PackProviderForApp) {
        self.language = language
        self.provider = provider
        _session = State(wrappedValue: VoiceIntentSession(configuration: .init(
            language: language,
            packProvider: provider,
            trust: .unverifiedForTesting,
            autoStopOnSilence: true)))
    }

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
                Text("Model: \(packVersion)").font(.caption).foregroundStyle(.tertiary)
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
            do {
                let url = try await provider.packURL(for: language.languageCode)
                let bundleURL = url.appendingPathComponent("bundle.json")
                if let data = try? Data(contentsOf: bundleURL),
                   let manifest = try? JSONDecoder().decode(NLUPackManifest.self, from: data) {
                    packVersion = manifest.version
                } else {
                    packVersion = "Unknown version"
                }
            } catch {
                packVersion = "Error loading pack"
            }
            
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
