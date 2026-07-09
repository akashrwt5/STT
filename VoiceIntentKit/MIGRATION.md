# Phase-2 Migration — Consolidate onto VoiceIntentKit

**Status:** _proposed — not executed._ This is the PR description for the follow-up
change that flips the STT app onto `VoiceIntentKit` and deletes the duplicated
in-app implementation.

Phase 1 (this branch) added `VoiceIntentKit` as a self-contained copy of the app's
STT + NLU stack, wired a third **Package** option on the first screen, and proved
parity via `VoiceIntentKitTests` (see `Tests/VoiceIntentKitTests/`). The app itself
was not modified beyond that additive integration. Phase 2 deletes the copies.

## Summary

- `PVAViewModel` and `LiveTranscriptionViewModel` build a `VoiceIntentSession`
  from `VoiceIntentKit` instead of constructing the classifier / coordinator /
  engine directly. All three UI paths (English, Multilingual, Package) route
  through the same package facade.
- Remove the duplicated Services / NLU / audio / recognition / model resources
  from the `STT` target — the package becomes the single source of truth.
- Public app API surface shrinks to Views + a thin ViewModel layer + the
  session facade. Everything else lives in the package.

## Pre-requisites (Phase 1 must be green)

1. Local package **VoiceIntentKit** added to the STT target
   (Xcode → *File → Add Package Dependencies… → Add Local…*).
2. `PackageVoiceView.swift` compiled without the `#if canImport` fallback path.
3. `VoiceIntentKitTests` green on iOS Simulator 26 (parity established).

## Step 1 — Flip the consumers onto the package

Replace the classifier/coordinator wiring in each ViewModel with a
`VoiceIntentSession`. The event stream (`session.events`) already carries
transcripts, dialog turns, state, and errors — the same information the
current ViewModels publish.

Files to modify (edit — do **not** delete):

| File | Change |
| --- | --- |
| `STT/STT/ViewModels/PVAViewModel.swift` | Own a `VoiceIntentSession`. Map `NLUVariant` → `VoiceLanguage`. Publish transcript/turn state from the session's `events` stream. |
| `STT/STT/ViewModels/LiveTranscriptionViewModel.swift` | Replace `TranscriptionCoordinator + NLUEngine` with a `VoiceIntentSession` (or drop this VM entirely if `PVAViewModel` subsumes it). |
| `STT/STT/ViewModels/FileTranscriptionViewModel.swift` | Uses `TranscriptionCoordinator` for file input. If the package exposes file transcription via its coordinator (`Core/`), route through it; otherwise keep this VM but import the coordinator from `VoiceIntentKit` (it's `public`). |
| `STT/STT/Views/STTTestView.swift` | Collapse `PipelineChoice` back into a single sheet — every choice constructs a `VoiceIntentSession` with the appropriate `VoiceLanguage`. Remove the branch that keys off `NLUVariant`. |
| `STT/STT/Views/PVASheetView.swift`, `LiveTranscriptionView.swift`, `FileTranscriptionView.swift` | Update type references (e.g. `TranscriptionState`, `NLUVariant`) to their package equivalents. |

## Step 2 — Delete the duplicated code

**Source files to remove from the STT target** (both from disk and the Xcode
project's file references — `File → Delete → Move to Trash`):

```
STT/STT/Audio/AudioCaptureService.swift
STT/STT/Audio/AudioSessionManager.swift
STT/STT/Audio/BufferConverter.swift
STT/STT/Audio/FileCaptureService.swift
STT/STT/Audio/SilenceDetector.swift
STT/STT/Coordinator/TranscriptionCoordinator.swift
STT/STT/Extensions/AVAudioPCMBuffer+AnalyzerInput.swift
STT/STT/Extensions/AVAudioPCMBuffer+Power.swift
STT/STT/Models/AudioInputState.swift
STT/STT/Models/IntentResult.swift
STT/STT/Models/SilenceDetectionConfiguration.swift
STT/STT/Models/TranscriptionError.swift
STT/STT/Models/TranscriptionResult.swift
STT/STT/Models/TranscriptionState.swift
STT/STT/Protocols/AudioInputProvider.swift
STT/STT/Protocols/TranscriptionDelegate.swift
STT/STT/Recognition/SpeechRecognitionService.swift
STT/STT/Services/IntentClassifierService.swift
STT/STT/Services/KeywordMatcher.swift
STT/STT/Services/MemoryProbe.swift
STT/STT/Services/MultilingualIntentClassifierService.swift
STT/STT/Services/SemanticClassifier.swift
STT/STT/Services/SemanticEmbedder.swift
STT/STT/Services/TFIDFLogisticScorer.swift
STT/STT/Services/NLU/ConversationSpeaker.swift
STT/STT/Services/NLU/EntityExtractor.swift
STT/STT/Services/NLU/LocalizationLoader.swift
STT/STT/Services/NLU/NLUContext.swift
STT/STT/Services/NLU/NLUEngine.swift
STT/STT/Services/NLU/NLUEngineFactoryProvider.swift
STT/STT/Services/NLU/NLULexicon.swift
STT/STT/Services/NLU/NLUProtocols.swift
STT/STT/Services/NLU/NLUResponse.swift
STT/STT/Services/NLU/NLUSchema.swift
STT/STT/Services/NLU/NLUVariant.swift
STT/STT/Services/NLU/SlotFormatting.swift
```

**Resource files/bundles to remove** (deleting these shrinks the app IPA by
~50 MB — CoreML models — plus JSON):

```
STT/STT/Resources/IntentClassifier.mlpackage
STT/STT/Resources/MiniLMEmbedder.mlpackage
STT/STT/Resources/SemanticHead.mlpackage
STT/STT/Resources/EnglishSpecific/IntentClassifier_en.mlpackage
STT/STT/Resources/EnglishSpecific/en_intent_classifier_weights.json
STT/STT/Resources/Multilingual/IntentClassifier_multilingual.mlpackage
STT/STT/Resources/Multilingual/calibration.json
STT/STT/Resources/Multilingual/multilingual_intent_classifier_weights.json
STT/STT/Resources/Multilingual/multilingual_intent_labels.json
STT/STT/Resources/Localization/*.json                (9 files: en/fr/de/da × 3)
STT/STT/Resources/intent_classifier_weights.json
STT/STT/Resources/minilm-vocab.txt
STT/STT/Resources/nlu_entities.json
STT/STT/Resources/nlu_schema.json
STT/STT/Resources/semantic_head.json
```

**Test files that become obsolete** (they cover code the app no longer owns —
their package equivalents in `VoiceIntentKitTests/` are the new home):

```
STTTests/KeywordMatcherTests.swift
STTTests/LocalizationLoaderTests.swift
STTTests/NLUEngineFactoryTests.swift
STTTests/ExtractDateTimeMultilingualTests.swift
STTTests/IntentClassifierCoreMLParityTests.swift
STTTests/Resources/coreml_golden_fixtures.json
STTTests/SpeechRecognitionServiceTests.swift        (if the package owns STT too)
STTTests/TranscriptionCoordinatorTests.swift        (ditto)
STTTests/AudioSessionManagerTests.swift             (ditto)
STTTests/Mocks/MockAudioInputProvider.swift         (ditto)
STTTests/Mocks/MockTranscriptionDelegate.swift      (ditto)
```

Keep `STTTests/STTTests.swift` and add app-level integration tests there for the
new `VoiceIntentSession`-driven ViewModels.

## Step 3 — Verify

- `xcodebuild -scheme STT test` — the ViewModel integration tests and any UI
  tests must pass against the flipped app.
- `xcodebuild -scheme VoiceIntentKit test` (iOS Simulator 26) — the ported
  parity suite in `VoiceIntentKitTests` remains green.
- Cold-launch the app, walk English → Multilingual → French on-device.
  Verify Stage-2 latency and Stage-3 rescue behave as they do today.

## Risk / rollback per group

| Group | Risk | Rollback |
| --- | --- | --- |
| ViewModel rewires | Publishing model changes; consumers of `@Published` types may need adjustment. UI regressions if `VoiceIntentEvent` mapping misses a case. | Revert the ViewModel diff. Package remains — the app just re-owns its state. |
| Delete `Services/*` + `Services/NLU/*` | Any lingering type reference in the app target fails compilation. Import cycles if a View still names `NLUEngine` directly. | `git revert` restores the sources; the package copy still exists side-by-side (Phase 1 state). |
| Delete `Audio/`, `Coordinator/`, `Recognition/`, `Extensions/`, `Models/`, `Protocols/` | Same as above, plus `FileTranscriptionViewModel` needs its coordinator source to change from local → `VoiceIntentKit`. | `git revert`. |
| Delete `Resources/*.mlpackage` + JSON | The app can no longer resolve `Bundle.main.url(forResource: "IntentClassifier", …)`. Anything still using `Bundle.main` (as opposed to the package's `Bundle.module`) will silently return nil. | Grep the codebase for `Bundle.main.url(forResource:` before deletion. Restore individual bundles with `git checkout` if needed. |
| Delete `STTTests/*` NLU tests | Coverage moves to `VoiceIntentKitTests`. If the CI job only ran `STT`'s scheme, model-parity coverage drops in that job. | Add the `VoiceIntentKit` scheme to CI. Restore individual tests with `git checkout`. |

## Notes for the reviewer

- The package's public API (`VoiceIntentSession`, `VoiceIntentConfiguration`,
  `VoiceIntentEvent`, `VoiceIntentTurn`) is deliberately narrow. If a
  ViewModel needs something the facade doesn't expose (e.g. per-buffer audio
  level metering — currently a `TranscriptionDelegate.didUpdateAudioLevel`
  callback), widen the facade in a separate reviewed PR, not this one.
- After this PR merges, `#if canImport(VoiceIntentKit)` guards in
  `PackageVoiceView.swift` can go — the package is unconditional.
- The `IntentKit/` folder (an earlier greenfield design) is dead code; it
  can be removed in the same PR or a follow-up.

## Swift language mode: package pinned to `.v5` to match the STT app

**Symptom on device (iPhone 17 Pro Max, iOS 26).** Tapping **Package** on
the first screen crashed ~1s after the mic started with an `EXC_BREAKPOINT`
(`brk #0x1`) on `com.apple.RealtimeMR_ForceQueue` —
`_dispatch_assert_queue_fail` inside `Speech.framework`. The app's own
English/Multilingual paths — running the same byte-copied code — did not
crash. Prior speculative fixes (start/analyzeSequence swap, feed-done
barrier) all failed with the same trap.

**Root cause.** The STT app builds with `SWIFT_VERSION = 5`; the package's
`Package.swift` declared `swift-tools-version: 6.0` with no explicit
language mode, so SwiftPM built the package under **Swift 6 strict
concurrency**. iOS 26's `SpeechAnalyzer` is an actor with a custom serial
executor pinned to `com.apple.RealtimeMR_ForceQueue`; under Swift 6 strict
scheduling, some of its internal async callbacks run on the cooperative
pool instead of that queue, tripping `dispatch_assert_queue()`. Swift 5's
scheduler behaves the way `Speech.framework` expects and the assertion
never fires.

**Fix.** Pin the package to Swift 5 mode:

```swift
let package = Package(
    // …
    targets: [ /* … */ ],
    swiftLanguageModes: [.v5]   // match STT.xcodeproj SWIFT_VERSION = 5
)
```

With that in place, `SpeechRecognitionService.swift` in the package
matches the app's copy byte-for-byte (`start(inputSequence:)` followed by
`finalizeAndFinishThroughEndOfInput()` — no barrier). The earlier
speculative "barrier" workaround has been reverted.

**If you ever move the package to Swift 6 strict** — the fix will need to
live inside `SpeechRecognitionService.swift`'s task-group structure (e.g.
route analyzer calls through an isolated helper, or use
`Task.detached` boundaries that respect the analyzer's custom executor).
That is a separate engineering task, not a migration blocker.

_(Previously this section documented an `analyzer.start + finalize`
sequencing "fix" and an `analyzeSequence` swap — both were wrong; the
symptom was queue affinity, not call order. Retained only as a note that
those diagnoses were rejected.)_

## Earlier package-only compile fixes (still valid under Swift 5)

These were introduced when the package briefly built under Swift 6 strict
mode; under Swift 5 they are valid no-ops / harmless attributes. Kept to
preserve intent for a future strict-mode migration:

- `NLU/MemoryProbe.swift` — `nonisolated(unsafe) static let byteFormatter`,
  and `getpagesize()` in place of `vm_kernel_page_size`.
- `NLU/NLUCore/EntityExtractor.swift` — `entitiesURL: URL? = nil` default
  with `Bundle.module` resolved inside `init` (public inits can't reference
  internal `Bundle.module` in a default argument in any language mode).
- `Core/Audio/AudioCaptureService.swift` — `@preconcurrency import
  AVFoundation`, `startEngine` marked `@MainActor`.
- `Core/Recognition/SpeechRecognitionService.swift` — `@preconcurrency
  import AVFoundation`, `@Sendable` on the feed-child `group.addTask`
  closure.

## Parser fix that lives only in the package

The package's `Sources/VoiceIntentKit/NLU/NLUCore/EntityExtractor.swift`
runs **D3 (decimal-hour idioms) before D1 (digit + spaced clock-hour marker)**
in `_extractDateTimeLexicon`. The app's copy of the same file still has D1
before D3.

**Symptom in the app today:** FR utterances of the form
`<N> heures <idiom>` (e.g. "dix heures et demie", "huit heures moins le
quart") return the wrong minute because D1 greedy-matches "N heures" and
consumes the digits before D3 can bind the idiom to "N". The bug was
introduced by commit `39e8a38` and refined by `486b299`.

**In Phase 2**, when the app's `EntityExtractor.swift` is deleted and the
package version takes over, the fix comes along for the ride — there is no
extra work to do. If you decide to backport the fix to the app *before*
Phase 2, cherry-pick the D2/D3/D1 reorder from the package's file and
re-run `STTTests/ExtractDateTimeMultilingualTests` — three cases flip from
red to green: `testFrenchFixtures` ("dix heures et demie" → 10:30, "huit
heures moins le quart" → 07:45) and `testHalbCountsDown_notUp` ("huit
heures moins le quart" → 07:45).

## Known aspirational test (not fixed here)

`VoiceIntentKitTests/LocalizationLoaderTests.testLexiconLoadsForFrenchAndNilForUnknown`
asserts the French lexicon has a **non-empty `no_idioms`** list. None of
`nlu_lexicon.fr.json`, `nlu_lexicon.de.json`, or `nlu_lexicon.da.json` (in
either the app or the package — the files are byte-identical) contains a
`no_idioms` key.

`NLUEngineFactoryProvider.MultilingualNLUEngineFactory.makeEngine(language:)`
already falls back to `NLUEngine.defaultNoIdioms` (the English list) when
the per-language lexicon lacks it, so this is by design. The test's
assumption is stronger than the design guarantees.

**Follow-up options** (pick one, in a separate PR):
- Weaken the test to allow either a populated list *or* the English
  fallback path (matches the design).
- Populate `no_idioms` in each non-English lexicon JSON if there are real
  language-specific idioms to add. This drifts the resource files from
  the current byte-exact-parity gate — verify with the Python side first.
