# Prompt — finish integrating & hardening VoiceAIKit

Copy everything below the line into a new session (or hand to a developer). It is self-contained.

---

You are a Principal iOS Engineer working in the `Starkey_Research/STT` repository. It contains an iOS 26 hearing-aid companion app (`STT.xcodeproj`) with an on-device speech-to-text + Dialogflow-replacement NLU stack, and a new Swift package **`VoiceAIKit/`** (a self-contained copy of that STT+NLU stack, exposing one facade `VoiceIntentSession`).

## Repo orientation (read these first)

- `VoiceAIKit/README.md` — the package's public API (`VoiceIntentSession`: `init`, `events`, `start()`, `stop()`, `reset()`, `classify(text:)`).
- `VoiceAIKit/INTEGRATION.md` — how to add the package to the app + the third "Package" picker option + the Phase-2 migration plan.
- `VoiceAIKit/Package.swift` — one target `VoiceAIKit`, iOS 26+, resources bundled (4 `.mlpackage` models via `.process`, JSON/vocab via `.copy`, `Localization/` as a subdir).
- `VoiceAIKit/Sources/VoiceAIKit/` — `Facade/` (public), `Core/` (STT), `NLU/` (3-stage classifier + `Engine/` dialog manager, TTS), `Pack/` (pack schema, integrity, loader), `Diagnostics/`.
- The app's original, still-canonical implementation lives in `STT/STT/Services/`, `STT/STT/Services/NLU/`, and `STT/STT/` (audio/recognition/coordinator). The package is a **copy** of these.

## Design invariants (do not violate)

- **One model, one language.** A `VoiceIntentSession` speaks exactly one language, chosen via `VoiceIntentConfiguration.language`. Keep the code language-neutral; never hard-code English behavior into the pipeline.
- **Single public surface.** Do not widen `VoiceIntentSession`'s public API without a clear reason; internal types stay internal.
- **Do not change the app's existing NLU/STT logic.** Additive changes only (new files, the third picker option). The package is where refactors happen.
- **Never hand-edit `project.pbxproj`** to add the package or files — that risks corrupting the project. Adding the local package and adding new files to the target are Xcode GUI steps; if you cannot perform them, produce exact instructions instead.
- **Byte-exact resources.** The classifier depends on exact JSON weights/vocab and golden fixtures — do not reformat or "optimize" resource JSON.

## Tasks

1. **Compile the package.** Build `VoiceAIKit` for an iOS 26 simulator in Xcode 26. Fix any compile errors introduced by the copy/adaptation (most likely: `Bundle.module` resource lookups, access levels, actor isolation, or a `SwiftPM` resource rule). Do not alter algorithm behavior. Report every change with a one-line rationale.

2. **Confirm resources load at runtime.** Run a tiny harness that constructs `VoiceIntentSession(configuration: .init(language: .english))` and calls `classify(text: "turn up the volume")`. Verify: (a) the CoreML `IntentClassifier` model loads (or the pure-Swift TF-IDF fallback engages — log which), (b) `nlu_schema.json` / `nlu_entities.json` load from `Bundle.module`, (c) a plausible intent comes back. Do the same for one non-English language (e.g. `.language(code: "fr", locale: "fr-FR")`) to confirm the `Localization/` overlays resolve.

3. **Wire the third "Package" option** on the app's first screen exactly as `INTEGRATION.md` describes: add the local package to the STT target (GUI step or instructions), add `STT/Views/PackageVoiceView.swift`, and apply the minimal `STTTestView.swift` diff so the segmented control reads **English · Multilingual · Package**, with "Package" driving `VoiceIntentSession`. Verify English/Multilingual still use the unchanged in-app path.

4. **Prove parity (Phase-2 gate).** Add a test target to `VoiceAIKit/Package.swift` and port the app's existing parity tests to run against the **package** sources: `IntentClassifierCoreMLParityTests`, `ExtractDateTimeMultilingualTests`, `KeywordMatcherTests`, `LocalizationLoaderTests`, `NLUEngineFactoryTests` (originals in `STTTests/`). They must pass unchanged against the package — green means the package is behaviourally identical to the app's implementation. If any resource is test-only (e.g. `coreml_golden_fixtures.json`), bundle it into the test target, not the library.

5. **Write the migration PR description** (do not execute it yet) for the Phase-2 consolidation from `INTEGRATION.md`: flip `PVAViewModel`/`LiveTranscriptionViewModel` onto the package, delete the duplicated `Services/`, `Services/NLU/`, and resource copies from the app target, and leave the package as the single source of truth. List exact files to delete and the risk/rollback for each.

## Acceptance criteria

- `swift build` / Xcode build of `VoiceAIKit` succeeds for iOS 26; no behavior changes beyond compile fixes.
- The English and one non-English `classify(text:)` smoke tests return sensible intents, with a log line stating which classifier stage answered.
- The app runs with a working third "Package" option that transcribes and classifies via the package; the other two options are unchanged.
- The ported parity test suite passes against the package.
- A migration PR description exists, but no existing app code has been deleted or rewired yet (that's a separate, reviewed change).

## Notes

- Resilience is intentional: missing/failed CoreML models fall back to pure-Swift TF-IDF (Stage 2) and skip MiniLM (Stage 3). A fallback is not a failure — log it, don't "fix" it by forcing the model.
- The obsolete `IntentKit/` folder (an earlier greenfield design) is dead — ignore or delete it.
- `Tests/VoiceAIKitTests/` is an empty placeholder; use it for Task 4.
- Info.plist of the host app must have `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` for the live-mic path.
