# VoiceAIKit — Verification of the Antigravity Over-Engineering Review

**Reviewer:** second-pass audit against source at `VoiceAIKit/Sources/VoiceAIKit` (11,404 LOC, 49 files) plus the host app target and `IntentKit/`.
**Method:** every claim traced to construction sites, conformers and call graphs — not to comments.

---

## Bottom line

The review's *thesis* is right: the Pack, OTA and endpointing layers are well-engineered and the defensive style is proportionate to a hearing-aid SDK.

Its *findings* are a mixed bag. Of the six flagged items:

| # | Claim | Verdict |
|---|-------|---------|
| 1 | `SilenceDetectionConfiguration` 15 params | **Diagnosis partly right, prescription wrong** — it is public API by design |
| 2 | `IntentResult.systemImage` | **Right, but badly understated** — the whole type is dead code |
| 3 | `TranscriptionDelegate` + `AsyncStream` dual delivery | **Inverted** — and it hides a real memory leak |
| 4 | `ConversationSpeaker` is a boundary violation | **Wrong** — it is load-bearing for turn-taking |
| 5 | `ClassificationBreakdown` piping | **Mostly right, mischaracterized** — it is public API, not debug data |
| 6 | `NLUSchema` re-projection | **Right, but built on a stale comment** |

And it **misses the four largest items in the codebase**, one of which it explicitly praised.

One credibility flag: the "What I did NOT flag" section defends *"The `OSAllocatedUnfairLock` in `SilenceDetector`"*. There is no lock in `SilenceDetector`. The file says the opposite in its header — *"Not thread-safe by design … carries no synchronisation overhead."* The locks are in `AudioCaptureService`, `FileCaptureService` and `AppAudioInputProvider`. That paragraph was not verified against the file.

---

## Part 1 — Verdicts on the six claims

### 1. `SilenceDetectionConfiguration` — diagnosis partly right, prescription wrong

**Claim:** 15 public `var`s, 3 presets, no custom callers → make it `internal`.

**What the code says.** The recommendation would break the package's own public contract. `VoiceIntentConfiguration` exposes two injection points:

```swift
public var commandSilence: SilenceDetectionConfiguration?      // VoiceIntentTypes.swift:132
public var slotAnswerSilence: SilenceDetectionConfiguration?   // VoiceIntentTypes.swift:135
```

consumed at `VoiceIntentSession.swift:300` and `:448`. And the doc comment on `.singleUtterance` instructs integrators to do exactly what the review says nobody does:

> *"For consistently slower speakers (e.g. hearing-aid users) raise `speechEndTimeout` to ~1.2s via a custom `SilenceDetectionConfiguration`."*

"No caller constructs a custom configuration" is true **inside this repo** — because the only host here is a demo app. It is a statement about the sample, not about the API. For a hearing-aid SDK, per-deployment endpoint tuning is the single most likely field-support lever; sealing it is the wrong direction.

**What is actually wrong.** The struct flattens two different audiences into one 15-slot initializer:

- *Integrator-tunable:* `isEnabled`, `speechEndTimeout`, `noSpeechTimeout`, `maxUtteranceDuration`, `adaptiveEndpointing`.
- *Algorithm internals no host can reason about:* `noiseFloorMarginDB`, `initialNoiseFloorDBFS`, `maxUtteranceWordBoundaryGrace`, `maxUtteranceHardCeiling`, `adaptiveSlope`, `adaptiveGraceStart`, `adaptiveMaxWindow`.

The second group has no meaning without reading `SilenceDetector` and `EndpointDecider`. Exposing them as peers of `speechEndTimeout` is what makes the surface feel like 15 interacting dials.

**Recommendation (revised):** keep it public. Split it — a public `SilenceDetectionConfiguration` with ~5 fields plus a nested `tuning: EndpointTuning = .default` holding the rest. Same behaviour, one comprehensible surface, no API removal. Severity: **low, cosmetic.**

---

### 2. `IntentResult.systemImage` — right, and much worse than stated

**Claim:** presentation logic in a domain model; move it to the host.

**What the code says.** `IntentResult` is **`internal`** (`IntentResult.swift:72` — `enum IntentResult: Sendable`, no `public`), so it is not "API surface weight." It is worse than that: **it is never constructed anywhere in the package.**

```
$ grep -rn "IntentResult\.\|\.intent(label:\|\.genai(" Sources/
Core/Models/IntentResult.swift:84   # its own accessor
```

Every other hit for `.interrupted(` resolves to `NLUResponse.interrupted` or `VoiceIntentTurn.interrupted`, not this enum. The pack-driven path produces `ClassificationResult` → `NLUResponse` → `VoiceIntentTurn`. `IntentResult` never enters it.

Three fields on `TranscriptionResult` are dead for the same reason:

```swift
var intentResult: IntentResult?            // never assigned outside init; init never passed one
var slots: [String: String]?               // same
var classificationBreakdown: ClassificationBreakdown?  // not even in the initializer
```

All three `TranscriptionResult(...)` construction sites (`SpeechRecognitionService.swift:658, 675, 808`) pass text/isFinal/locale only.

**Recommendation (revised):** don't move it — **delete it.** ~135 lines (the enum, `systemImage`, `displayLabel`, `humanize`, `insertSpaces`) plus the three dead `TranscriptionResult` fields. Keep only `ClassificationBreakdown` and `ClassificationResult`, which share the file and are live, and move them to a file named for them. The host app already carries its own identical copy at `STT/STT/Models/IntentResult.swift`, which is what `TranscriptionResultCard.swift:91` actually calls — so nothing is lost. Severity: **medium (dead code in a shipped SDK), zero-risk fix.**

---

### 3. `TranscriptionDelegate` + `AsyncStream` — the review has this backwards

**Claim:** the delegate is vestigial; the Facade uses neither; keep the `AsyncStream`.

**What the code says.** The Facade uses the delegate. Directly:

```swift
// VoiceIntentSession.swift:686
extension VoiceIntentSession: TranscriptionDelegate {
    func didReceivePartialResult(_ text: String) { … continuation.yield(.partialTranscript(text)) }
    func didReceiveFinalResult(_ text: String)   { … classifyTask = Task { await engine.handle(text) } }
    func didEncounterError(_ error: TranscriptionError) { … markNotRunning(); state = .stopped }
}
```

wired at `VoiceIntentSession.swift:299` (`coordinator.delegate = self`). This is the entire live path — every transcript, every classification, every fatal-error teardown. The claim "the Facade … doesn't use either" is factually wrong, and "deprecate the delegate, keep `AsyncStream`" would delete the working path.

The opposite is true. `coordinator.results` has **zero consumers**:

```
$ grep -rn "for await" Sources/ | grep results
(nothing — the only `for await result in` is over `fileStream`, a *local* stream)
```

**And it is still being written to.** `TranscriptionCoordinator.swift:541, 548` yield every partial and every final into `resultsContinuation`, which points at a stream created with:

```swift
let (stream, continuation) = AsyncStream<TranscriptionResult>.makeStream()   // line 117
```

No `bufferingPolicy` → **`.unbounded`**. Nothing ever iterates it, so every partial result — several per second during speech — is retained for the lifetime of the coordinator, which is deliberately long-lived (`liveProvider` is reused across turns to avoid re-creating `AVAudioEngine`). Each retained element holds a `UUID`, `String`, `Locale`, `Date` and two optionals.

**This is a live memory leak in the always-on path of a hearing-aid SDK.** The review looked straight at both lines and read the symptom as an API-design smell.

**Recommendation:** delete `results`/`resultsContinuation` from the live path entirely, or at minimum `makeStream(bufferingPolicy: .bufferingNewest(1))`. Keep the delegate. (See also Part 2A: the file path that `results` exists to serve is itself unreachable.) Severity: **high — correctness, not aesthetics.**

---

### 4. `ConversationSpeaker` — wrong

**Claim:** TTS doesn't belong in an NLU SDK; its only consumer is the host ViewModel; extract it.

**What the code says.** Its consumer is the Facade:

```swift
private let speaker = ConversationSpeaker()                        // VoiceIntentSession.swift:61
speaker.onFinish = { [weak self] in self?.handleSpeechFinished() } // :122
speaker.onCancel = { [weak self] in self?.handleSpeechCancelled() }// :123
await self.speaker.speak(text, locale: coordinator.currentLocale)  // :564
```

with `speaksPrompts: Bool = true` as the public default.

More importantly, the review is wrong about the *architecture*, not just the call graph. VoiceAIKit is not a speech-to-intent package; it is a **half-duplex conversational session**, and TTS is the other half of the turn-taking state machine:

- `speakSerialized()` stops the mic with `deactivateSession: false`, waits for the recognizer to drain, *then* speaks — so the recognizer never transcribes the SDK's own prompt. That handoff needs both ends.
- `didReceiveFinalResult` and `didReceivePartialResult` both `guard state != .speaking` — self-echo suppression, only possible if the session knows it is speaking.
- `onFinish` is what advances the dialog and reopens the mic for a slot answer. That *is* multi-turn dialog control.
- The `AVAudioSession` is one shared `.playAndRecord` configuration owned by `AudioSessionManager` and used by both mic and synthesizer.

Handing TTS to the host means handing it the turn-taking contract: "stop the mic, wait for drain, speak, tell me when you're done, don't let me classify your own audio." Every host would reimplement it, and get it wrong. The package already supports the extraction path the review wants — `speaksPrompts = false` + `hostDidFinishSpeaking()` — and it is correctly *mandatory* in `.appProvided` audio mode. That is the right design: owned by default, delegable by contract.

**What is actually worth fixing:**

- **File location.** `NLU/Engine/ConversationSpeaker.swift` is wrong — it has nothing to do with NLU. It belongs in `Core/Audio/` or `Facade/`. This is the review's one valid point here, buried under an incorrect conclusion.
- **A real race the review didn't find.** `speak()` sets `isSpeaking = true`, then `await`s a hop onto `speechQueue` before calling `synth.speak(utterance)`. If `stop()` runs during that window it guards on `synthesizer.isSpeaking` — still `false`, because nothing has been enqueued — and returns a no-op. The queued utterance then plays *after* the session was stopped. In this product that means the assistant speaks into the user's ear after they cancelled. Fix: have `stop()` bump `speakGeneration` and have the queued block check its generation before calling `speak`.

Severity: **the review's recommendation is high-risk and should be rejected;** the file move is cosmetic; the stop-race is a **real bug**.

---

### 5. `ClassificationBreakdown` piping — mostly right, wrong frame

**Claim:** debug instrumentation masquerading as domain data across 4 layers; side-channel it.

**Correct on the mechanics.** The piping is real: `ClassificationResult.breakdown` → `NLUResponse.fulfill/.fallback` → `NLUSession.pendingBreakdown` (carried across turns, `NLUEngine.swift:427, 440`) → `VoiceIntentSession.stages(from:)`.

**Wrong on the frame.** It is not debug data. It terminates in **public API**:

```swift
public struct VoiceIntentStages: Sendable {          // VoiceIntentTypes.swift:194
    public let winningStage: Int?
    public let stage2Score: Double?
    public let stage3Score: Double?
}
case fulfilled(…, viaSemanticRescue: Bool, stages: VoiceIntentStages?)
case notUnderstood(intent: String, confidence: Double, stages: VoiceIntentStages?)
```

"Side-channel it" is therefore an API break, not a refactor — and for a hearing-aid deployment, per-stage confidence on a fulfilled turn is legitimately actionable by the host (a low stage-2 score on a device-control intent is a reason to confirm rather than act). The `pendingBreakdown` carry across a slot-filling flow is deliberate: it attributes the *fulfilled* turn to the stage that classified the *opening* utterance, which is the only correct attribution.

The one genuinely dead link in the chain is `TranscriptionResult.classificationBreakdown` (see Claim 2) — never written, never read.

**Recommendation (revised):** keep the public `stages`. Delete the dead `TranscriptionResult` field. Optionally collapse `NLUResponse`'s trailing `breakdown:` + `semanticRescue:` + `confidence:` into a single `Attribution` value to shrink the case signatures — a signature cleanup, not a layering fix. Severity: **low.**

---

### 6. `NLUSchema` re-projection — right conclusion, stale evidence

**Correct** that there is an extra hop and that the lookup chain is 4 deep.

**But the quoted comment is out of date, and the review inherited its staleness.** `PackEngineFactory.swift:22-24` says deletion is "mechanical once this path is proven live," naming `EntityExtractor`, `NLULexicon`, `LocalizationLoader`, `LanguagePackRegistry`, `ClassifierBundle` and `Resources/`. **All six are already gone** from the package — they survive only as prose in comments explaining what replaced them. The comment describes a migration that has since completed.

Also, `schema(from:)` is not "copies data into a struct with slightly different field names." It does real work the engine cannot do for itself: it **resolves response *keys* into localized *strings*** against `pack.responses`, and it is where the confirmation-gate policy join happens. That is the language binding, and it correctly happens once at build time rather than per-turn. `DialogSchema.swift`'s own header documents that the `Decodable` conformances were deliberately removed so these types can no longer be loaded from unverified JSON — i.e. they were already promoted from "legacy bundle model" to "factory output."

**Recommendation (revised):** the honest framing is *naming and comment debt*, not an extra layer. Rename `NLUSchema`/`IntentDef`/`FollowupDef` to something that says "resolved dialog tables for one language" (`ResolvedDialog`, `ResolvedIntent`, `ResolvedConfirmation`), and delete the stale paragraph in `PackEngineFactory`. Inlining `ResolvedPack` into `NLUEngine` would push per-turn response-key lookups into the engine — a regression, not a simplification. Severity: **low; do the rename, skip the inline.**

---

## Part 2 — What the review missed

### A. ~250 lines of file-transcription code unreachable from the public API — *and the review praised it*

The review calls `FileCaptureService` part of "the minimum viable abstraction for the three real audio sources." There are **two** reachable sources. `AudioSource` is:

```swift
public enum AudioSource { case microphone; case appProvided(sampleRate: Double) }
```

There is no file case, and no public entry point reaches `transcribeFile`. Unreachable from the package's public surface:

- `TranscriptionCoordinator.transcribeFile(...)` — ~80 lines (`:343-420`)
- `FileCaptureService` — 126 lines
- `fileServiceFactory`, `fileCompletionHandler`, `recognitionServiceDidComplete`
- `TranscriptionState.processingFile(progress:)` and its `Equatable`/`isActive` arms
- `AudioInputProvider.progressStream`
- the `results`/`resultsContinuation` machinery from Claim 3 — **this is the only thing it was ever for**

No test exercises it either (`grep -rn transcribeFile Tests/` → nothing).

This is the single largest concrete over-engineering finding in the package, and it explains Claim 3's leak: the stream is a leftover of a feature the Facade never exposed. Either add a public `transcribeFile` to `VoiceIntentSession` (the app has a `FileTranscriptionViewModel`, so there may be intent to) or delete the lot. **Do not leave it half-wired.** Severity: **high.**

### B. Two full parallel implementations compile into the app

`STT/STT/` is a complete pre-package copy of the pipeline — 38 files including its own `SpeechRecognitionService`, `TranscriptionCoordinator`, `SilenceDetectionConfiguration`, `NLUEngine`, `ConversationSpeaker`, `EntityExtractor`, `NLULexicon`, `LocalizationLoader`, `IntentClassifierService`, `MultilingualIntentClassifierService`, `SemanticClassifier`, `TFIDFLogisticScorer`.

It is **in the app target**: `STT.xcodeproj/project.pbxproj:38` declares `PBXFileSystemSynchronizedRootGroup` with `path = STT`, so everything under it is compiled. And the app's live view models use the *copy*, not the package — `LiveTranscriptionViewModel.swift:44` sets `coordinator.silenceConfiguration` on the local `TranscriptionCoordinator`; only `STTApp.swift`, `PackageVoiceView.swift` and `NLUOTAManager.swift` `import VoiceAIKit`.

There is a **third** stack: `IntentKit/` (its own `NLUEngine`, `NLUPipeline`, `IntentResult`), imported by nothing outside itself.

The review scoped itself to the package and so concluded "not over-engineered." At system level, the dominant finding is that three implementations of the same on-device NLU ship in one repo, two of them dead, one of them still compiled into the binary. Every bug fixed in `VoiceAIKit` has a silent twin in `STT/STT/`. Severity: **highest — and it is what to fix first.**

### C. Two orchestrators for one pipeline

`VoiceIntentSession` (744 lines) and `TranscriptionCoordinator` (580 lines) both own lifecycle, state and audio-session policy, and the coordinator is now `internal` with exactly one consumer. Its header still claims *"The single public entry point for all transcription operations … The rest of the app only touches this class"* — untrue since the Facade pass. Once (A) removes the file path, the coordinator is a mic-lifecycle + locale-resolution helper, and about a third of it (permission plumbing, `AudioSessionManagerDelegate`, state transitions) duplicates concerns the session already tracks. Worth a merge pass, after (A). Severity: **medium.**

### D. Stage-3 lifecycle leaks through two protocol layers

`IntentClassifying` carries `warmUp()`, `loadStage3()`, `releaseStage3()` — CoreML memory management — and `ConversationEngine` re-declares all three purely to forward them. A dialog engine's contract should not include "release the MiniLM embedder." `NLUProtocols.swift` even documents `ConversationEngine` as *"Contract the ViewModel depends on … `LiveTranscriptionViewModel` stores `any ConversationEngine`"* — that ViewModel is in the host app and cannot see this internal protocol. Both the abstraction and its justification are stale. `ConversationEngine` has one conformer and no test double. Severity: **low-medium.**

### E. Unguarded logging volume on the hot path

`SpeechRecognitionService` has **57** `logger.info` calls, unguarded by `#if DEBUG`, several inside per-buffer paths, several interpolating transcript text. `os_log` redacts non-literal strings by default so this is not a PII leak, but it is per-turn work in an always-on audio pipeline on a power-constrained target. The review classified this as "appropriate for debugging audio pipelines" — appropriate at `.debug`, which the package already uses correctly elsewhere (`lifecycleLog`). Demote the per-buffer ones. Severity: **low.**

---

## Priority order

1. **B** — resolve the three-implementation problem. Delete `STT/STT/` and `IntentKit/`, or move them out of the build. Nothing else is safe to reason about until the app compiles one pipeline.
2. **A + 3** — decide file transcription in or out; delete the unconsumed unbounded `AsyncStream` either way. This is a live leak.
3. **2** — delete the dead `IntentResult` and the three dead `TranscriptionResult` fields (~135 lines, zero risk).
4. **4 (stop-race)** — fix `ConversationSpeaker.stop()` generation guard. **Reject** the extraction recommendation; do the file move.
5. **C** — collapse the coordinator into the session after (A).
6. **1, 5, 6, D, E** — cosmetic: split the config struct, rename the dialog types, delete the stale `PackEngineFactory` paragraph, demote hot-path logs.

Items **1** (make it internal), **3** (deprecate the delegate), **4** (extract TTS) and **6** (inline `ResolvedPack`) as the original review wrote them would each make the package worse. Do not action them as stated.

---

## What holds up from the review

The praise sections are accurate where they matter and worth keeping:

- The Pack load sequence and `join()`'s referential-integrity checks are correctly assessed. Each check maps to a real VIK defect and gates the next stage.
- `NLUPackInstaller`'s claim → smoke-test → commit with generation guards, and the `checksums_root` token comparison, are correctly defended. Actor isolation genuinely is not mutual exclusion across `await`.
- `PackStorageController`'s `NSRecursiveLock` is correctly defended — `commitStagingAndActivate` → `activate` → `cleanup` is genuinely recursive.
- `EndpointDecider`'s extraction is correctly defended. It is pure, clock-free, and 142 test functions exist because of choices like it.
- `SpeechRecognitionService`'s three-child `TaskGroup` (feed / analyzer / results) is the right concurrency shape, and its length is not by itself a defect.

The `OSAllocatedUnfairLock` in `SilenceDetector` paragraph is the exception — that lock does not exist.
