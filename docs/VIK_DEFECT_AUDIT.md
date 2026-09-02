# VoiceAIKit — Defect Audit

Independent read of the package (not a response to the earlier review). Findings are from static analysis with `file:line` evidence — none of these were reproduced on device, so treat P0s as "read the code path and confirm", not as filed bugs.

Ordered by what actually bites you in the field.

---

## P0 — these will produce field reports

### 1. `startLiveTranscription()` has a re-entrancy hole → two live sessions → mic stuck open

Three defects that compose into one field failure.

**(a) The guard is too weak.** `TranscriptionCoordinator.swift:245`

```swift
await teardownTask?.value          // ← suspension point
teardownTask = nil
guard !state.isActive, state != .stopping else { return }
```

`TranscriptionState.isActive` is `true` only for `.transcribing` and `.processingFile` (`TranscriptionState.swift:35-42`). It is **false** for `.requestingPermissions` and `.preparingAudio` — the two states a start spends most of its wall-clock time in (permission round-trips, `sessionManager.configure()`, model asset checks).

So: call A passes the guard, transitions to `.requestingPermissions`, suspends on permissions. Call B arrives, `teardownTask` is now `nil` so the first `await` doesn't suspend, and B's guard **passes** — `.requestingPermissions` is not "active". Two starts now run concurrently.

**(b) `startTranscribing` doesn't defend itself.** `SpeechRecognitionService.swift:230-348`

It resets all session state (`hasReceivedFinalResult = false`, `lastPartialText = ""`, `finalizedTranscript = ""`, …), bumps `generation`, and then assigns `analysisTask = Task { … }` — **overwriting the handle to a task that may still be running**. The previous task is never cancelled and never awaited, and its handle is now unreachable, so it can never be cancelled.

**(c) The results loop is not generation-guarded.** `SpeechRecognitionService.swift:600-690`

`consumeResults` writes shared instance state on every iteration:

```swift
self.hasReceivedFinalResult = true       // via appendFinalizedSegment path
self.lastPartialText = running
self.firstSpeechAt = CFAbsoluteTimeGetCurrent()
self.delegate?.recognitionService(self, didReceivePartialResult: …)
```

with no `generation == myGeneration` check anywhere in the loop. The generation guard exists (`:513`, `:528`) but only wraps the *completion* and *failure* callbacks. The comment at `:71-74` claims a stale session "can never fire a spurious completion or error" — true, and it quietly concedes the rest: a stale session **can** fire spurious partials and **can** corrupt the live session's transcript state.

**The failure.** Stale loop sets `hasReceivedFinalResult = true` on the shared instance. The new session's endpointer then hits:

```swift
// SpeechRecognitionService.swift:802
guard !didSynthesizeFinal, !hasReceivedFinalResult, !lastPartialText.isEmpty else { return }
```

→ returns early → **no final is ever delivered** → `VoiceIntentSession.didReceiveFinalResult` never runs → NLU never fires → the mic stays open until `maxUtteranceDuration` (60s default) force-commits. From the user's seat: *"I asked it something and it just sat there listening."*

**Who triggers it.** Not a synthetic race:

- `TranscriptionCoordinator.swift:521` — `audioSessionManagerInterruptionEnded` fires `Task { try await startLiveTranscription() }` when a phone call ends. Nothing coordinates that with a host-initiated `start()` or with `handleTurnAdvance()` resuming after TTS. Phone call ends while the user taps the mic → both paths start.
- `VoiceIntentSession.start()` is documented as safe to call again (`:184-186`), so a host double-tap is a supported input.

**Fix:** (i) `guard state == .idle else { return }` — reject any non-idle state, or set a synchronous `starting` flag before the first `await`; (ii) `startTranscribing` should `await stopTranscribing()` (or at least `analysisTask?.cancel(); await analysisTask?.value`) before building a new one; (iii) capture `myGeneration` in `consumeResults` and bail on mismatch at the top of the loop, same as the completion path already does.

---

### 2. `stop()` during a start is silently ignored — the mic turns on after the user cancelled

`stopLiveTranscription` (`TranscriptionCoordinator.swift:300`):

```swift
guard state != .idle, state != .stopping else { return }
transition(to: .stopping)
teardownTask = Task { await recognitionService.stopTranscribing() … transition(to: .idle) }
```

If state is `.requestingPermissions` or `.preparingAudio`, this transitions to `.stopping` and runs a teardown against a recognizer that hasn't started yet — a no-op. Meanwhile the **in-flight start continues past its own awaits**, calls `recognitionService.startTranscribing(...)` and then `transition(to: .transcribing)`.

Net: user taps stop while the permission sheet or the model load is up; teardown completes; then the mic starts. There is no cancellation token and no post-await state re-check in `startLiveTranscription` — after each `await` it never asks "am I still supposed to be starting?"

**Fix:** re-check state after every suspension in the start path, or hold a `startTask` handle that `stopLiveTranscription` cancels.

---

### 3. The default mic path uses an unbounded audio queue — and the code already knows better

`AudioCaptureService.swift:57`:

```swift
return AsyncStream<AVAudioPCMBuffer> { [weak self] continuation in
```

No `bufferingPolicy` → **`.unbounded`**. The tap yields deep-copied 4096-frame buffers from the real-time audio thread.

Now compare `AppAudioInputProvider.swift:69-73`:

```swift
let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
    bufferingPolicy: .bufferingNewest(32)
)
// "Bounded so a slow consumer can never grow memory without limit — the newest
//  audio wins, which is the correct policy for live speech (stale backlog is worthless)."
```

The correct policy, with the correct reasoning, applied to the host-push path that almost nobody uses — and not to the built-in microphone, which is the default.

This matters because the consumer genuinely can stall. The feed child does **2–4 `await` hops onto `@MainActor` per buffer** (`SpeechRecognitionService.swift:398, 403, 414, 429`): `reportAudioLevel`, `shouldEndpointForMaxDuration`, `shouldEndpointForStableTranscript`, `shouldStopForSilence`. Every one waits for the main thread. A SwiftUI render storm or a slow delegate and the queue grows at ~16 KB per 85 ms with no ceiling, and the audio the endpointer sees drifts behind wall-clock — which is what the endpointer measures against.

**Fix:** `.bufferingNewest(32)` on the mic stream too. See also #11 for the deeper version of this.

---

### 4. `TranscriptionCoordinator.results` — unbounded stream, written every partial, read by nobody

`TranscriptionCoordinator.swift:117`:

```swift
let (stream, continuation) = AsyncStream<TranscriptionResult>.makeStream()   // .unbounded
```

Yielded to on every partial and every final (`:541`, `:548`). `grep -rn "for await" Sources/` finds no consumer — the only `for await result in` is over `fileStream`, a *local* stream inside `transcribeFile`.

So during every live turn, every partial result (`UUID` + `String` + `Locale` + `Date` + optionals) is retained forever. The coordinator is deliberately long-lived (`liveProvider` is cached across turns to avoid re-creating `AVAudioEngine`, `:81`), so this accumulates for the lifetime of the session object.

It exists only to serve `transcribeFile`, which is itself unreachable — see #12.

**Fix:** delete `results`/`resultsContinuation` from the live path.

---

### 5. `ConversationSpeaker.stop()` is a no-op during the queue hop — TTS plays after cancellation

`ConversationSpeaker.swift:85-118`:

```swift
func speak(...) async {
    isSpeaking = true
    await withCheckedContinuation { continuation in
        Self.speechQueue.async {
            … synth.speak(utterance)      // ← enqueued here
            continuation.resume()
        }
    }
}

func stop() {
    guard synthesizer.isSpeaking else { return }   // ← still false during the hop
    synthesizer.stopSpeaking(at: .immediate)
}
```

Between `isSpeaking = true` and `synth.speak(utterance)` actually landing on `speechQueue`, `stop()` sees `synthesizer.isSpeaking == false` and returns without doing anything. The queued utterance then speaks.

On this product that means the assistant talks into the user's ear after they cancelled the session. `VoiceIntentSession.stop()` (`:316`) and `deinit` (`:178`) both go through this path.

**Fix:** bump `speakGeneration` in `stop()` and have the `speechQueue` block check its captured generation before calling `synth.speak`.

---

## P1 — correctness and security

### 6. Zip-slip: the archive is extracted before anything is verified, and containment is never checked

`PackValidator.swift:88-95`:

```swift
public func extractAndValidate(from packageURL: URL, into stagingDirectory: URL) throws -> PackIdentity {
    // 1. Extraction
    try extractor.extract(from: packageURL, to: stagingDirectory)
    // 2. bundle.json exists
    // 3. FULL trust chain — Ed25519, checksums_root, per-file digests, unsigned sweep
```

The trust boundary is crossed at step 1. `PackExtractor` is host-supplied (`:5-9`, "inject their preferred ZIP extraction library (e.g. ZIPFoundation)"), and nothing in the SDK checks that what was written stayed inside `stagingDirectory`. A `.nlu` with entries named `../../Library/Preferences/…` writes outside the pack root **before a single signature byte is checked**.

The "nothing unsigned is hiding in the tree" sweep does not catch it — `PackIntegrity.unsignedFiles` (`:196-210`) enumerates *under* `packRoot` and computes paths relative to it. Files written outside `packRoot` are invisible to it by construction.

This inverts the layer's own stated property. The comment at `PackValidator.swift:24-28` is right that there is now one verifier and one trust policy — but the write happens before the verifier runs at all.

**Fix:** ship a safe extractor, or validate post-extraction that every file under `stagingDirectory` standardizes to a path still prefixed by `stagingDirectory`, and refuse the pack otherwise. Cheap, and it closes an arbitrary-file-write from a downloaded artifact.

### 7. Unsanitized path components from public API and from the manifest

`PackStorageController.swift:88`:

```swift
private func languageDirectory(for language: String) throws -> URL {
    let url = packsURL.appendingPathComponent(language, isDirectory: true)
```

`language` comes straight from the public `NLUPackInstaller.preparePack(from:language:)`. It flows into `stagingDirectory(for:clean: true)` which does `try fileManager.removeItem(at: staging)` (`:105`). A host passing `"../../Documents"` — by bug, not by malice — deletes a directory outside the pack store.

`version` is worse in principle: `commitStagingAndActivate(version:)` (`:147-162`) builds `langDir.appendingPathComponent(version)` and calls `removeItem` then `moveItem` on it, and `version` originates in the pack manifest. Under a production trust policy the manifest is signature-covered, so it's contained — but the containment is entirely someone else's signature, with no local check. A compiler bug that emits `version: ".."` in a legitimately signed pack deletes the language directory.

There is no validation anywhere in the file (`grep sanitiz|allowed|CharacterSet` → one unrelated `isEmpty`).

**Fix:** one guard — reject any component containing `/`, `..`, or a leading `.` — applied to both.

### 8. Slot answers get re-classified as new intents before the awaited slot is even filled

`NLUEngine.swift:250-270`:

```swift
private func handleSlotFilling(_ text: String) async -> NLUResponse {
    …
    let probe = await classifier.classifyAsync(text)
    let isNewIntent = probe.label != intent && … && probe.confidence >= 0.75
    if isNewIntent { … return .interrupted(...) }

    // only NOW do we try to fill the slot we actually asked for
    if let awaiting, let slot = cfg.slots.first(where: { $0.name == awaiting }) { … }
```

Two problems.

**Ordering.** The topic-switch probe runs *before* the answer is tried against the awaited slot. So the user's answer to your own question can cancel your own question.

**This is reproduced, not hypothesised.** Running the shipped pack's own TF-IDF + logistic head (`models/intent/en/intent_classifier_weights.json`, 57 labels, `temperature = 0.822109`) over the vectorisation in `PackTFIDFVectorizer`, for answers to `reminders.add.ask_name` ("What do you want to be reminded about?"):

| user says | classified as | conf | outcome |
|---|---|---:|---|
| "Need to go to walk" | `Cmd.ActivityWalk` | 0.994 | **flow cancelled** |
| "clean my hearing aids" | `Help_CleanCare` | 1.000 | **flow cancelled** |
| "charge my hearing aids" | `Help_Battery` | 0.979 | **flow cancelled** |
| "send a message to John" | `Cmd.SendMessage` | 1.000 | **flow cancelled** |
| "turn up the volume" | `Cmd.VolumeIncrease` | 0.999 | **flow cancelled** |
| "find my phone" | `Cmd.FindMyPhone` | 1.000 | **flow cancelled** |
| "go running" | `Cmd.ActivityRun` | 1.000 | **flow cancelled** |
| "check my battery" | `Cmd.BatteryLevel` | 0.926 | **flow cancelled** |
| "start transcribing" | `Cmd.TranscribeStart` | 0.962 | **flow cancelled** |
| "call mom" | vacuous → out-of-scope | 0.000 | ok |
| "drink water" | vacuous → out-of-scope | 0.000 | ok |
| "my doctor appointment" | `reminders.add` | 0.684 | ok |

The interrupt threshold is 0.75. These are not marginal — they are 0.93 to 1.00.

Two things make it worse than the threshold alone suggests:

- **Temperature sharpens, it does not soften.** `temperature = 0.822 < 1`, so logits are *divided* by 0.822 before softmax. Calibration was fitted for the 0.70 in-distribution gate; its side effect is that out-of-distribution inputs also come back near 1.0. A 0.75 interrupt threshold sitting on top of a distribution deliberately sharpened for a different purpose has almost no discriminating power left.
- **The flow survives only by accident.** "call mom", "drink water", "buy milk" are safe purely because they produce *no vocabulary features at all* and route to out-of-scope via the `isVacuous` path (`PackEngineFactory.swift:238-246`). The moment a reminder subject overlaps the command vocabulary, it is gone. For a hearing-aid product, "remind me to clean my hearing aids" and "remind me to charge my hearing aids" are close to the most likely reminders a user will ever set — and both are 0.98+ cancellations.

**Distribution.** The classifier was trained on commands. A bare slot answer is out-of-distribution input, and a confidence score on OOD input is not a quantity you can threshold. "take my medicine" → `Cmd.VolumeDecrease` at 0.174 is the same defect showing its other face: the score is meaningless, it just happened to land low.

**Cost.** You are also paying a full TF-IDF vectorisation + CoreML inference on every single slot turn to compute this.

### 8b. The fix, and why it does not break a real topic switch

The obvious worry: if the slot is filled before the probe runs, a genuine mid-flow switch gets swallowed. Concretely — `Cmd.MemoryChange` asks "which memory?" and the user says "increase volume".

It does not break, and the pack data is why. `memory` is `"open": false, "type": "list"` with 38 gazetteer values (`entities/shared/content.json`); `remind` is `"open": true`. A closed gazetteer gives a hard "this is not a valid value for this slot" signal that an open entity cannot.

Simulating `PackEntityExtractor.extract` (exact → synonym → Levenshtein fuzzy, `minLength 5`, `ratio 0.3`) against the classifier probe, for answers to `Cmd.MemoryChange.ask_memory_name`:

| user says | gazetteer fill | classifier probe | today | after reorder |
|---|---|---|---|---|
| "increase volume" | — none — | `Cmd.VolumeIncrease` 1.00 | interrupt | **interrupt** ✓ |
| "turn up the volume" | — none — | `Cmd.VolumeIncrease` 1.00 | interrupt | **interrupt** ✓ |
| "find my phone" | — none — | `Cmd.FindMyPhone` 1.00 | interrupt | **interrupt** ✓ |
| "what is my battery" | — none — | `Cmd.BatteryLevel` 0.97 | interrupt | **interrupt** ✓ |
| "restaurant" | `Restaurant` @1.00 | `Cmd.MemoryChange` 0.45 | fill | fill ✓ |
| "resturant" (misheard) | `Restaurant` @0.90 fuzzy | out-of-scope 0.00 | fill | fill ✓ |
| "turn on music" | `Music` @1.00 | `Cmd.VolumeUnmute` 0.87 | **interrupt — wrong** | **fill** ✓ |
| "custom two" | `Custom Two` @1.00 | `Help_MemoryOptions` 0.77 | **interrupt — wrong** | **fill** ✓ |

Every genuine topic switch still interrupts, because none of them resolve against the gazetteer. And the reorder *repairs* two live defects in the memory flow: "turn on music" currently unmutes the volume instead of selecting the Music memory, and "custom two" — a literal value in the gazetteer — currently plays a help topic instead of switching to it.

The principle: **the most specific evidence wins.** An exact gazetteer hit is near-certain; a softmax score over out-of-distribution text is weak. Today the weak signal runs first and vetoes the strong one.

**The rule, by fill strength:**

| awaited slot | outcome | action |
|---|---|---|
| closed, exact/synonym hit (≥0.95) | unambiguous answer | fill, no probe |
| closed, no match | cannot be an answer | probe → interrupt as today |
| closed, fuzzy hit (0.60–0.90) | genuinely ambiguous | probe, and confirm if they disagree |
| open (`remind`) | anything fills | fill; only an explicit cancel escapes |

Every input this needs already exists: `Match.confidence` and `Match.isFuzzy` (`PackEntityExtractor.swift:37`), the `open` flag, and the `negative` lexicon.

### 8c. There is no way out of an open slot today

The open-slot row above needs an escape, and the engine does not have one. `negative` — `["cancel", "do not", "don't", "nah", "negative", "never mind", "nevermind", "no", "no thanks", "nope", "stop"]` — is loaded at `NLUEngine.swift:100` and consulted **only** inside `yesNo()` (`:233`), which is reachable only from `handleConfirmation`. The slot-filling path never looks at it.

So during "What do you want to be reminded about?", saying **"cancel"** does this: `extract("remind", "cancel")` finds nothing → `entities.isOpen("remind")` is true → `value = text` → **you get a reminder named "cancel"**, and the flow completes.

This is a defect on its own, independent of the reorder — and it is also the escape hatch the open-slot case needs. Consulting `negative` for a whole-utterance match before the open-entity fallback fixes both.


### 8d. Provenance — when this was introduced

Traced through git. It is a regression, not an original design flaw.

| commit | date | what happened |
|---|---|---|
| — | before 2026-06-20 | `handleSlotFilling` filled the awaited slot, ran `extractAllSlots`, called `advanceSlots`. **No probe.** "Need to go to walk" filled the reminder name correctly. |
| `13653cb` | 2026-06-20 | *"Add intent interruption handling to slot-filling (mirrors Python NLUEngine)"* — inserted the probe **at the top of the method**, ahead of the fill. This is the regression. Authored by Claude Opus 4.8 per the commit trailer. |
| `40eebf5` | 2026-07-09 | *"created VoiceIntentKit package"* — copied verbatim into the package. |
| `408d78c` | 2026-08-21 | Changed the hardcoded `"Default Fallback Intent"` to `schema.fallbackIntent`. Cosmetic; the ordering untouched. |

Nothing else has touched it in 172 commits. It has been live for ~2.5 months.

**Two things about `13653cb` explain the blind spot.**

*Its worked example is command-shaped.* The commit message reasons from: "set a reminder" → "what to remind?" → **"change memory to Car"**. That utterance has an imperative verb and a carrier, and it classifies `Cmd.MemoryChange` @ 1.000. The feature was designed and hand-checked against interruptions that *look like commands*. A plain descriptive answer — "Need to go to walk" — was never in scope, and it scores just as high (`Cmd.ActivityWalk` @ 0.994). The threshold cannot separate them because the difference is grammatical, not one of confidence.

*It shipped with no tests.* `13653cb` touched 5 files, none of them a test. Today, across 142 test functions, there is no interruption test at all — the only occurrence of `.interrupted` in the suite is one enum case in an unrelated `switch` (`VoiceIntentSessionSmokeTests.swift:248`). A code path that can cancel any in-progress dialog, gated on a magic constant, has never been executed by a test.

**One thing to verify outside this repo.** The commit claims it mirrors Python's `_handle_slot_filling`. The Python source (`IntentClassifier/scripts/nlu/engine.py`, referenced throughout the file headers) is not in this repo or its history, so the ordering could not be checked against it. Worth confirming: if Python fills first and probes second, this is purely a porting error and the server side is fine. If Python also probes first, the same bug is live there and the fix belongs in both.

**Note the residual case the fix must still handle.** `13653cb` was solving a real problem — before it, "change memory to Car" during the reminder-name prompt became a reminder literally named "change memory to Car". `remind` is an open entity, so fill-first alone reintroduces that. This is the open-slot row in 8b, and a cancel-word check is not sufficient for it: the escape signal there has to be command *shape* (imperative verb / carrier match), not confidence and not a cancel keyword. The pack's `lexicon.carriers` regexes are the closest existing material.


### 9. Data race on `AudioInputProvider.state`

`AudioCaptureService` is `final class … @unchecked Sendable` (`:16`). The continuation is carefully lock-protected (`:31-34`, with a comment about exactly this) and `stopped` is an `OSAllocatedUnfairLock` — and `state` sits right next to them as a bare `private(set) var` written from three isolation domains: `start()` (any context, `:55`), `stop()` (any context, `:79`), `startEngine()` (`@MainActor`, `:131`, `:135`). `AppAudioInputProvider` has the same shape.

`@unchecked Sendable` is what suppresses the diagnostic. Getting the continuation right and leaving `state` unguarded next to it is the tell that the annotation was applied to make the build pass rather than after auditing every stored property.

**Fix:** put `state` behind the same lock, or make it atomic.

---

## P2 — architecture and hygiene

### 10. The real-time audio path is routed through the main actor

`SpeechRecognitionService` is `@MainActor` (`:41`). Its feed child is deliberately non-isolated so conversion and RMS stay off the main thread — and then it hops back to the main actor 2–4 times per buffer to read `hasVolatileText`, `lastPartialChangeAt`, `firstSpeechAt` and to report the audio level.

The endpointing state is a handful of `Bool`s, `String`s and `CFAbsoluteTime`s. There is no reason for the decision to require the UI thread. In a Siri/Alexa-class pipeline the audio path never touches the UI thread; here the "should I commit this turn?" decision is serialized behind whatever SwiftUI is doing.

**Fix:** move the endpoint state into a lock-protected box (or make the service an `actor` with a `@MainActor` delegate shim) so the feed child reads it without a main-actor hop. This also removes the backpressure source behind #3.

### 11. Dead code shipping in the SDK

- **`IntentResult`** (`Core/Models/IntentResult.swift:72-203`, ~135 lines including the 60-line SF-Symbol switch and `humanize`) — **never constructed anywhere in the package**. `grep -rn "IntentResult\.\|\.intent(label:\|\.genai("` returns only its own accessor. Every other `.interrupted(` hit is `NLUResponse` or `VoiceIntentTurn`.
- **`TranscriptionResult.intentResult`, `.slots`, `.classificationBreakdown`** (`:24-28`) — never assigned. `classificationBreakdown` isn't even in the initializer. All three construction sites (`SpeechRecognitionService.swift:658, 675, 808`) pass text/isFinal/locale only.
- **File transcription** — `transcribeFile` (`TranscriptionCoordinator.swift:343-420`), `FileCaptureService` (126 lines), `fileServiceFactory`, `fileCompletionHandler`, `recognitionServiceDidComplete`, `TranscriptionState.processingFile`, `AudioInputProvider.progressStream`, and the `results` stream from #4. `AudioSource` is `.microphone | .appProvided` — there is no public entry point that reaches any of it, and no test covers it.

That's ~400 lines of unreachable code in a shipped SDK, one piece of which (#4) is an active leak.

### 12. Three implementations of the same pipeline in one repo, two of them compiled

`STT/STT/` is a complete pre-package copy — 38 files, its own `SpeechRecognitionService`, `TranscriptionCoordinator`, `NLUEngine`, `ConversationSpeaker`, `SilenceDetectionConfiguration`, `EntityExtractor`, `NLULexicon`, `LocalizationLoader`, `IntentClassifierService`, `SemanticClassifier`, `TFIDFLogisticScorer`.

It is in the app target: `STT.xcodeproj/project.pbxproj:38-42` declares a `PBXFileSystemSynchronizedRootGroup` with `path = STT`, so everything beneath it compiles. And the live view models use the **copy**, not the package — `LiveTranscriptionViewModel.swift:44` sets `silenceConfiguration` on the local `TranscriptionCoordinator`; only `STTApp.swift`, `PackageVoiceView.swift` and `NLUOTAManager.swift` `import VoiceAIKit`.

`IntentKit/` is a third stack (own `NLUEngine`, `NLUPipeline`, `IntentResult`), imported by nothing outside itself.

Practical consequence: **every fix in this audit has a silent twin in `STT/STT/` that won't get it.** Anyone reviewing "the code" is reviewing one of three answers.

### 13. Two orchestrators for one pipeline

`VoiceIntentSession` (744 lines) and `TranscriptionCoordinator` (580) both own lifecycle, state and audio-session policy. The coordinator is now `internal` with exactly one consumer, and its header still claims *"The single public entry point for all transcription operations … The rest of the app only touches this class"* — untrue since the Facade landed. Once #11 removes the file path, roughly a third of it (permission plumbing, state transitions, `AudioSessionManagerDelegate`) duplicates what the session already tracks. It is also where #1 and #2 live: two state machines, one of them not authoritative, is how a start/stop race gets written in the first place.

### 14. Hot-path logging

`SpeechRecognitionService` has 57 `logger.info` calls, none behind `#if DEBUG`, several on per-buffer paths, several interpolating transcript text. `os_log` redacts non-literal strings by default so this is not a PII leak, but it is unconditional work in an always-on audio pipeline on a power-constrained target. The package already uses `.debug` correctly elsewhere (`lifecycleLog`) — the per-buffer ones should match.

---

## Suggested order

1. **#12** — get to one pipeline. Nothing else is verifiable while the app compiles two.
2. **#1, #2, #3** — the start/stop race and the unbounded mic queue. These are the field reports.
3. **#6, #7** — the OTA path traversal. Cheap guards, and it is a downloaded artifact writing to disk.
4. **#4, #5** — the leaked stream and the TTS stop race.
5. **#8** — slot-answer misrouting. Ordering fix is small; the OOD-confidence issue needs a threshold study.
6. **#9, #11** — lock `state`, delete the dead code.
7. **#10, #13, #14** — the structural cleanup, once the above is stable.

## What is genuinely well built

Not padding — this is where the codebase is above the bar, and it's worth not regressing:

- **`PackIntegrity.verify`** — signature over `manifest ‖ bundle.json`, `checksums_root` binding, per-file digests, and an unsigned-file sweep, with `bundle.json` parsed from the *verified bytes* rather than re-read. That last detail (`Verified.bundleJSONBytes`) is the part most implementations get wrong. The only gap is that it runs after extraction (#6).
- **`NLUPackInstaller`** — claim → smoke-test → commit, with the `checksums_root` token guard rather than a version comparison, and the explicit acknowledgement that actor isolation is not mutual exclusion across `await`. The reasoning in those comments is correct.
- **`EndpointDecider`** — pure, clock-free, injectable time. This is why the endpointing math is testable at all, and 142 test functions exist partly because of choices like it.
- **`PackEngineFactory.schema(from:)`** — resolving response keys to localized strings once at build time instead of per-turn is the right call, and `DialogSchema`'s removal of `Decodable` (so these types can't be loaded from unverified JSON) is a real hardening step.
- **The `@Sendable` tap closure comment** in `AudioCaptureService.swift:106-118` — correctly diagnoses a Swift 6 isolation trap most people fix by guessing.
