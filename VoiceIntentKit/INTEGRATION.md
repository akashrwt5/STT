# Integrating VoiceIntentKit into the STT app

This wires a third **"Package"** option onto the first screen, alongside *English* and *Multilingual*. When selected, the session runs entirely through `VoiceIntentKit` instead of the app's in-project pipeline. Your existing code is left untouched — only additive changes.

> **One step I could not do for you.** Adding a local Swift package to an Xcode project edits `project.pbxproj`. Hand-editing that file blind risks corrupting the project, so — per your "don't do it wrong" instruction — I left it to you. It's a 30-second GUI step (Step 1 below). Everything else is provided as ready-to-paste code.

---

## Step 1 — Add the local package (Xcode GUI)

1. In Xcode: **File → Add Package Dependencies…**
2. Click **Add Local…**, choose the `VoiceIntentKit` folder (next to `STT.xcodeproj`).
3. When prompted, add the **VoiceIntentKit** library product to the **STT** app target.

Verify: the STT target → *General → Frameworks, Libraries, and Embedded Content* now lists `VoiceIntentKit`.

## Step 2 — Add the demo view (new file, additive)

Create `STT/Views/PackageVoiceView.swift` and paste this. It uses only the package's public API:

```swift
// PackageVoiceView.swift — session driven entirely by VoiceIntentKit.
import SwiftUI
import VoiceIntentKit

struct PackageVoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session = VoiceIntentSession(configuration: .init(
        language: .english,
        packProvider: PackProviderForApp(),       // see STT/Views/PackageVoiceView.swift
        trust: .unverifiedForTesting))            // production builds pin their own key
    @State private var transcript = ""
    @State private var status = "Idle"
    @State private var lastTurn = ""
    @State private var listening = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
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
                        else { listening = true; try? await session.start() }
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
                case .partialTranscript(let t), .finalTranscript(let t): transcript = t
                case .stateChanged(let s): status = "\(s)"; if s == .stopped { listening = false }
                case .error(let m): lastTurn = "Error: \(m)"; listening = false
                case .turn(let turn): lastTurn = describe(turn)
                }
            }
        }
    }

    private func describe(_ t: VoiceIntentTurn) -> String {
        switch t {
        case .followUp(let q, _):                   return "❓ \(q)"
        case .confirmation(let q):                  return "✅? \(q)"
        case .fulfilled(let i, let s, _, let c, _): return "🎯 \(i) \(s.isEmpty ? "" : "\(s)") (\(String(format: "%.2f", c)))"
        case .notUnderstood(_, let c):              return "🤷 not understood (\(String(format: "%.2f", c)))"
        case .interrupted(let cancelled):           return "↩︎ cancelled \(cancelled)"
        }
    }
}
```

## Step 3 — Add the third picker option (small edit to `STTTestView.swift`)

`NLUVariant` intentionally stays untouched (adding a case there would ripple into the factory's exhaustive `switch`). Instead, use a tiny local selector in the first screen. Apply this minimal diff to `STTTestView`:

```diff
 struct STTTestView: View {
     @State private var pvaViewModel: PVAViewModel?
+    /// Set when the user picks "Package" — presents the VoiceIntentKit-backed screen.
+    @State private var showPackageSession = false
     @AppStorage("selectedNLUVariant") private var variant: NLUVariant = .english
+    /// First-screen selection including the package path. English/Multilingual map to
+    /// the existing NLUVariant flow; Package routes to VoiceIntentKit.
+    @State private var pipeline: PipelineChoice = .english

+    enum PipelineChoice: String, CaseIterable, Identifiable {
+        case english, multilingual, package
+        var id: String { rawValue }
+        var title: String {
+            switch self { case .english: "English"; case .multilingual: "Multilingual"; case .package: "Package" }
+        }
+    }
```

Replace the existing variant `Picker` with:

```swift
Picker("Pipeline", selection: $pipeline) {
    ForEach(PipelineChoice.allCases) { Text($0.title).tag($0) }
}
.pickerStyle(.segmented)
.padding(.horizontal, 32)
.onChange(of: pipeline) { _, new in
    if new != .package, pvaViewModel != nil { pvaViewModel?.teardown(); pvaViewModel = nil }
    if new == .english { variant = .english }
    if new == .multilingual { variant = .multilingual }
}
```

And update the CTA action to branch:

```swift
Button {
    PVALaunchClock.tapped()
    if pipeline == .package {
        showPackageSession = true                      // VoiceIntentKit path
    } else {
        pvaViewModel = PVAViewModel(variant: variant)  // existing in-app path
    }
} label: { /* unchanged */ }
```

Finally add the sheet:

```swift
.sheet(isPresented: $showPackageSession) {
    PackageVoiceView().preferredColorScheme(.dark)
}
```

That's it — running the app now shows **English · Multilingual · Package**, and "Package" drives the whole session through `VoiceIntentKit`.

---

## Phase-2 migration — make the package the single source of truth

You now have two copies of the NLU/STT logic: the app's in `STT/STT/…`, and the package's. That's intentional for this phase (your constraint was "don't change existing code"), but two copies drift. When you're ready to consolidate:

1. **Verify parity.** Run the existing test suite (`ExtractDateTimeMultilingualTests`, `IntentClassifierCoreMLParityTests`, `KeywordMatcherTests`, `LocalizationLoaderTests`, `NLUEngineFactoryTests`) against the package sources by adding a package test target that imports them. Green = behavioural equivalence.
2. **Flip the app onto the package.** Change `PVAViewModel` / `LiveTranscriptionViewModel` to build the package's `VoiceIntentSession` (or expose the package's `NLUEngineFactoryProvider`) instead of the in-project types.
3. **Delete the duplicates.** Remove `STT/STT/Services/`, `STT/STT/Services/NLU/`, and the resource copies from the app target; keep them only in the package. Move the STT `Core/` files similarly if you want the package to own STT too.
4. **Single resource home.** Resources now live only in the package (`Bundle.module`); delete the app-bundle copies to shrink the app and remove the second maintenance point.

After Phase 2, the package is the canonical implementation and the app is a thin consumer — the production-maintainable end state.
