# VoiceAIKit — Architecture Refactor Execution Plan (v2.4)

> **v2.1** — self-review pass. Added §0 (what is verified vs reasoned), a
> hard "do not stash" rule in §1.1, a CI-runner capability check and
> fallback in §1.2, §1.4 (the app's duplicate tree — a scope call to make
> before PR 2), a state-machine enumeration step ahead of PR 2's `started`
> guard, Option C (serialized turn chain) plus the residual race in §4.2,
> and #10 reframed from "rejected" to "awaiting sign-off".
>
> **v2.2** — consistency pass. Fixed §1.3/§1.4 ordering, corrected the
> moved-file count in §2.0 (23, not 16), added §2.6 (five other docs name
> the renamed paths), added the `ExampleOTAManager.swift` rot risk to §6.3,
> and de-staled the §7 heading and the intro paragraph after the #10
> reframe.
>
> **v2.3** — §2.0 split into three commits (moves / headers / content edits);
> the `resolveLocale` deletion and the doc-path fixes had no commit assigned.
>
> **v2.4** — added §7.5, the decision record for overlapping turns, and
> reversed the earlier ranking of its two options; §4.2 now points at it
> instead of carrying a half-argued A/B/C list.

Supersedes the first-pass "All 10 Recommendations" task list. Same ten
recommendations; the sequencing, the risk ratings and several of the
*instructions* have changed after reading the code they describe.

**What changed from v1, in one paragraph.** Phases 1–2 were correct and are
carried over almost verbatim. Phase 3 contained a false statement about actor
isolation that would have removed a race guard, mis-enumerated the lock call
sites in `PackStorageController`, and missed the one live bug in the file it
was about. Phase 4's three tasks were priced as one unit when they are an easy
one, a hard one that needs a design decision first, and one this plan
argues should not be done at all — a call left open for sign-off in §7.3.
Every correction is traced in §8.

---

## Status

Branch: `fix/ota-unification-and-concurrency-Architecture-Refactor-plan-imp`.
The sections below this one are the original plan, kept for the reasoning. This
section is the current state.

### The ten recommendations

| # | What | State |
|---|---|---|
| 1 | Surface errors from fire-and-forget Tasks | Done |
| 3 | `NLUPackInstaller` → actor | Done |
| 4 | `Data/` → `Pack/`, `NLUCore/` → `Engine/` | Done |
| 5 | `VoiceIntentClient` → `Facade/` | Done |
| 6 | `MemoryProbe` → `Diagnostics/` | Done |
| 7 | Delete dead `resolveLocale` | Done |
| 2 | Split `SpeechRecognitionService` | Partial. `consumeResults` extracted (§4). `AssetManager` (§7.1) and the endpointing split (§7.2) are open. |
| 8 | Audio feed `nonisolated(unsafe)` | Open (§7.4). The approach in the original plan was inverted; read §7.4 before starting. |
| 9 | `PackStorageController` recursive lock | Open (§5). Readability only — nothing is broken, and this is the most safety-critical file in the OTA path. |
| 10 | Eliminate `NLUSchema` | **Decision pending** (§7.3). Recommended won't-do. |

All three open items are maintainability, not defects.

### Done, but not in this plan

The plan's own work turned up more than it listed:

- **`stop()` did not stop.** An unowned classification task survived it and reopened
  the microphone. `started` existed for this and was written twice, read never.
- **Conversation state leaked across sessions.** `NLUEngine.handle()` mutates its own
  slot-filling state before returning, so a discarded turn left the engine collecting
  while the session had forgotten. "set a reminder" → stop → start → "turn up the
  volume" produced a reminder named "turn up the volume".
- **`deinit` never released the audio session.** `AVAudioSession` is a process-wide
  singleton, so an unbalanced activation outlived every object involved.
- **Swift 6.** The package now builds and runs in `.v6`. The `.v5` pin had been
  attributed to `SpeechAnalyzer`'s custom executor; the stack showed it was our own
  `installTap` block inheriting `@MainActor`. One `@Sendable` fixed it. See
  MIGRATION.md.
- **Public `@unchecked Sendable` removed** from `PackValidator` and
  `PackStorageController`. Both were blocked only by `FileManager`, which is now
  `nonisolated(unsafe)` at the property. The four that remain are internal.

### Open, found during the work

| What | Why it matters |
|---|---|
| `VoiceIntentConfiguration.loadsSemanticRescue` does nothing | `loadStage3()` has an empty body and `semanticRescue` is never true. A host sets it, gets nothing, and is not told. Wire it, document it, or remove it. |
| Fixtures have no link to a pack version | `PackDateTimeParityTests` and `TopicDerivationParityTests` are the only tests comparing Swift against the Python reference. Nothing checks the fixture was generated from the pack being shipped, so they can pass while testing behaviour that no longer matches. |
| `AudioSessionManager` notification handlers | `@MainActor @objc`, registered without a `queue:`. Tested by hand on route change and interruption under Swift 6 and did not trap, but it is the same shape as the `installTap` bug. |

### Deferred by decision

Not forgotten, chosen against:

- **CI for `VoiceAIKitTests`.** No workflow runs the package suite; the safety net is a
  local `xcodebuild test` per change.
- **The app's duplicate tree.** `STT/STT/` still carries its own copy of the STT stack,
  so every fix in this branch — `stop()`, the conversation leak, `deinit`, the swallowed
  errors, and the `installTap` `@Sendable` — is still absent there. It cannot crash while
  the app builds in Swift 5, but the `@Sendable` one must land before the app moves to
  Swift 6. `MIGRATION.md` phase 2 removes the duplication.
- **`Core/` → `Speech/`.** `Core/` is 19 files, all of them the audio→text pipeline, and
  it is the only top-level folder named for its importance rather than its contents.
  Three findings came out of the same look and are also open:
  `NLU/Engine/ConversationSpeaker.swift` is TTS, not NLU, and is the only file in `NLU/`
  importing AVFoundation — move it and "no AVFoundation under `NLU/`" becomes a testable
  invariant; `Core/Models/IntentResult.swift` holds `ClassificationBreakdown`, which is
  NLU; and `NLU/` now contains one child directory and no files.

### If you pick this up

Nothing here blocks shipping. In rough order of value:

1. Sign off or overrule #10 (§7.3). It is the last open recommendation.
2. §7.5 — the generation tag. `started` is a Bool and cannot say *which* session run a
   task belongs to, so two `beginListening()` calls can still overlap across a fast
   stop→start. Small, and it finishes the lifecycle work rather than leaving it
   half-closed across three commits.
3. `loadsSemanticRescue`. Shipping a public option that silently does nothing is worse
   than not having it.
4. The readability items — #2's remainder, #8, #9 — after that, in any order.

---

## 0. Confidence — read this before trusting a line number

This plan was produced by **reading** the code, not by compiling it. No step
below has been run against a compiler or a simulator. That distinction matters
per-PR:

- **Verified by inspection, high confidence:** `Package.swift` has no explicit
  `sources:` list; `STT.xcodeproj` uses `XCLocalSwiftPackageReference`; a
  `VoiceAIKit` shared scheme exists; `resolveLocale` has zero callers inside
  the package; `started` is written twice and never read; `cleanup(...)` does
  not take the lock; `PackValidating` and `PackStorageControlling` are already
  `public protocol … : Sendable`; `TranscriptionState.isActive` excludes
  `.preparingAudio`; `startLiveTranscription()` has no teardown on its throw
  path. PR 1, PR 2 and PR 4 rest on these.
- **Reasoned, needs a compile before you trust the estimate:** every proposed
  diff in PR 3, PR 5 and PR 6. Spike them on a throwaway branch first.
- **Judgment, no measurement:** every effort number in §9. They are a
  correction of v1's optimism, not a measurement.

---

## Role

**Principal iOS Engineer** throughout. Unchanged from v1:

- **Architectural rigour** — every move, rename or refactor preserves
  compile-time guarantees (access control, `Sendable`, actor isolation) and
  runtime behaviour (thread safety, async cancellation, error propagation).
- **Zero regression tolerance** — the full package test suite passes before
  the next task starts. See §1.2: today that is a manual promise, and §1.2
  is how it stops being one.
- **Swift concurrency best practices** — `actor` over `@unchecked Sendable`
  + locks, structured over fire-and-forget `Task { }`, `nonisolated`
  extraction over `nonisolated(unsafe)` proliferation. With the caveat in
  §6.2: a `nonisolated(unsafe)` **local** consumed by one child task is
  already the strong form, and promoting it to a stored property is a
  downgrade, not an upgrade.
- **Documentation discipline** — preserve VIK-XXX references. Several file
  headers narrate their own move history (`DialogSchema.swift`: "Was
  `NLU/NLUCore/NLUSchema.swift`"). **Append to that history, never rewrite
  it.**
- **Ship-safe incrementalism** — each numbered PR below is standalone and
  independently revertible.

---

## 1. Preflight — blocking, before any code

### 1.1 — Clean the working tree

`git status` currently shows 7 modified files, including
`Facade/VoiceIntentSession.swift` and `NLU/NLUCore/NLUEngine.swift` — the two
files PR 2/PR 3 and (former) task 4.3 touch. "Rollback: `git checkout`" does
not work against uncommitted changes in the same files.

**Stash is not an option here.** Two of the modified files —
`NLU/NLUCore/NLUEngine.swift` and `NLU/NLUCore/NLUResponse.swift` — live in the
directory PR 1 renames to `NLU/Engine/`. A `git stash pop` after that rename
conflicts on a path that no longer exists, and you resolve it by hand at the
worst possible moment.

- [ ] **Land or discard** (not stash) the in-flight work in
      `VoiceIntentSession.swift`, `VoiceIntentTypes.swift`, `NLUEngine.swift`,
      `NLUResponse.swift`, `ConfirmationAndSlotFlowTests.swift`,
      `VoiceIntentSessionSmokeTests.swift`, `STT/Views/PackageVoiceView.swift`
- [ ] If that work is not ready to land, finish it first — PR 1 is cheap to
      postpone and expensive to interleave
- [ ] `git status` is clean before PR 1 opens

### 1.2 — Pin the test command, then put it in CI

v1 said "Run tests" fifteen times and never once said how. The package
declares `platforms: [.iOS("26.0")]` and uses `SpeechAnalyzer`, so a host
`swift test` is not obviously viable.

- [ ] Determine and record the canonical invocation at the top of this file,
      e.g.
      `xcodebuild -scheme VoiceAIKit -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.0' test`
- [ ] **Every** "run tests" checkbox below means exactly that command.
      Record the pass/fail in the PR description.

CI catches none of this today. The only workflow,
`.github/workflows/ios-coreml-parity.yml`, is app-scoped, path-filtered to
`STT/STT/Services/IntentClassifierService.swift` + `STTTests/**`, and pinned
to branch `claude/coreml-temperature-ios`. `VoiceAIKitTests` never runs in CI.

- [ ] **Hour one: confirm a hosted runner can even do this.** The package
      needs Xcode 26 / an iOS 26 simulator. If GitHub's `macos-latest` image
      does not carry it, this gate blocks everything after PR 1 — find out
      before planning around it, not after.
- [ ] Fallback if it cannot: (a) self-hosted runner on a build Mac, or
      (b) CI runs `xcodebuild build` + the subset of tests that do not need
      `SpeechAnalyzer`, and the full suite stays a documented local gate with
      its result pasted into every PR description. Pick one and write it here.
- [ ] Add `.github/workflows/voiceaikit-tests.yml` — runs the package test
      suite on push and PR, path-filtered to `VoiceAIKit/**`, no branch pin
- [ ] **Merge that workflow before PR 2.** PR 1 is file moves and can go
      first; everything from PR 2 on is behaviour and needs the net.

### 1.3 — Record a baseline

- [ ] Run the suite on the clean tree; record pass count and duration
- [ ] Note any already-failing tests **by name** in the PR description, so a
      pre-existing failure is never mistaken for a regression introduced here

---

### 1.4 — Scope boundary: the app's duplicate tree (decide before PR 2)

`STT/` carries a near-duplicate of the package's STT stack
(`STT/STT/Recognition/SpeechRecognitionService.swift`,
`STT/STT/Coordinator/TranscriptionCoordinator.swift`,
`STT/ViewModels/LiveTranscriptionViewModel.swift`). `MIGRATION.md` says phase 2
collapses the two; until then they drift independently.

This matters for PR 2 and PR 3 specifically: the same fire-and-forget shape
exists app-side (`LiveTranscriptionViewModel.swift:405`). **Fixing only the
package leaves the shipping app with the bug.**

- [ ] Audit whether `LiveTranscriptionViewModel` / `PVAViewModel` reproduce the
      PR 2 defect (a classification task that survives stop and reopens the mic)
- [ ] Decide and write it down: **port** the PR 2/PR 3 fixes to the app copy in
      the same PR, or **defer** to MIGRATION phase 2 and accept a known-stale
      app copy
- [ ] If deferring, add a `VIK-` entry to `BUG_TRACKER.md` so the app-side
      defect is tracked rather than forgotten

---

## 2. PR 1 — Structural moves (Recommendations #4, #5, #6, #7)

**Risk: none.** Verified: `Package.swift` declares
`.target(name: "VoiceAIKit", path: "Sources/VoiceAIKit")` with no explicit
`sources:` list, and `STT.xcodeproj` consumes the package as an
`XCLocalSwiftPackageReference` (not individual file refs). Moves inside
`Sources/VoiceAIKit` are invisible to both build systems. No import changes —
one module.

### 2.0 — Commit hygiene (new)

23 files move in this PR (14 out of `Data/`, 7 in the `NLUCore/` →
`Engine/` rename, plus `VoiceIntentClient` and `MemoryProbe`). Rename
detection is worth protecting.

- [ ] Use `git mv` for every move
- [ ] **Commit 1 — moves only, zero content edits.** All 23 renames, nothing
      else. Verify with `git show -M --stat` that git reports renames, not
      add/delete pairs
- [ ] **Commit 2 — header updates.** Append the new path history to each moved
      file's existing narration; do not rewrite it
- [ ] **Commit 3 — content edits.** §2.5 (delete the dead `resolveLocale`
      extension) and §2.6 (fix the five docs that name the old paths) are code
      and doc *changes*, not moves. Keeping them out of commits 1 and 2 is what
      keeps rename detection clean and makes the deletion reviewable on its own
- [ ] Breakdown of the 23, so the count is checkable at review time:
      14 (`Data/`) + 7 (`NLUCore/`) + `VoiceIntentClient.swift` +
      `MemoryProbe.swift`. That is 44% of the package's 52 Swift files — the
      reason this PR goes first rather than last

### 2.1 — `VoiceIntentClient.swift` → `Facade/` (#5)

- [ ] `git mv Sources/VoiceAIKit/VoiceIntentClient.swift Sources/VoiceAIKit/Facade/`

### 2.2 — `MemoryProbe.swift` → `Diagnostics/` (#6)

- [ ] `mkdir Sources/VoiceAIKit/Diagnostics`
- [ ] `git mv Sources/VoiceAIKit/NLU/MemoryProbe.swift Sources/VoiceAIKit/Diagnostics/`
- [ ] Note: called from `Core/Recognition/SpeechRecognitionService.swift`
      (lines ~194, 905) — same module, no import change

### 2.3 — `Data/` → `Pack/{Schema,Integrity,Loader}` (#4)

Unchanged from v1 — the mapping was right. One addition:

- **Schema:** `NLUBundle`, `PackSections`, `PackLexicon`, `DialogSchema`,
  `ResolvedPack`
- **Integrity:** `PackIntegrity`, `VoiceIntentError`
- **Loader:** `BundleDataLoader`, `PackEngineFactory`, `PackIntentClassifier`,
  `PackEntityExtractor`, `PackSlotResolver`, `PackTFIDFVectorizer`,
  `PackDateTimeParser`

- [ ] **Reconsider `DialogSchema.swift`'s destination.** v1 files it under
      `Pack/Schema/`. It is not pack *format* — it is the engine-facing
      projection **built by** `PackEngineFactory.schema(from:)`. It belongs in
      `Pack/Loader/`, next to the only thing that constructs it. (This also
      absorbs most of the value former task 4.3 was chasing — see §7.3.)
- [ ] Delete the now-empty `Data/`

### 2.4 — `NLU/NLUCore/` → `NLU/Engine/` (#4)

- [ ] `git mv Sources/VoiceAIKit/NLU/NLUCore Sources/VoiceAIKit/NLU/Engine`

### 2.5 — Delete dead `resolveLocale` (#7) — **corrected**

v1's check was `grep -r "resolveLocale" Sources/`. Run from the repo root
that hits the app's **separate copy** at
`STT/STT/Recognition/SpeechRecognitionService.swift:853`, which **is** used
(`STT/Views/LanguageSelectorView.swift:74`,
`STT/STT/Coordinator/TranscriptionCoordinator.swift:453`, two files in
`STTTests/`). You would conclude "used" and take the deprecate branch, which
is the wrong branch.

- [ ] Scope the check to the package:
      `grep -rn "resolveLocale" VoiceAIKit/Sources VoiceAIKit/Tests`
- [ ] Expected result: one hit, the definition at
      `Core/Recognition/SpeechRecognitionService.swift:972`. Zero callers.
- [ ] **Delete** the `extension SpeechRecognitionService` block (~966–1001).
      Do not deprecate.
- [ ] In the commit message, record that the app's copy stays alive until
      `MIGRATION.md` phase 2 collapses the two trees — so the next reader does
      not "fix" the asymmetry

### 2.6 — Update the docs that name the old paths (new)

Five documents reference directories PR 1 renames. Leave them and the repo's
own onboarding material starts lying on day one:

- [ ] `VoiceAIKit/MIGRATION.md` (2 references)
- [ ] `VoiceAIKit/PUBLIC_API_PLAN.md` (1)
- [ ] `VoiceAIKit/NEXT_STEPS_PROMPT.md` (1)
- [ ] `docs/ON_DEVICE_NLU_TECHNICAL_DETAILS.md` (1)
- [ ] `docs/NEXT_SESSION_PROMPT.md` (2)
- [ ] Sweep with
      `grep -rn "NLUCore\|VoiceAIKit/Data/\|Sources/VoiceAIKit/Data" --include=*.md .`
      and confirm zero hits outside this plan's own history section
- [ ] Do this in **commit 2** (the header-updates commit), not commit 1 —
      commit 1 stays content-free so rename detection works

### PR 1 acceptance

- [ ] Build succeeds (package + app)
- [ ] Full suite green, same pass count as the §1.3 baseline
- [ ] `git show -M --stat` shows renames, not add/delete pairs

---

## 3. PR 2 — Session lifecycle: stop() does not stop (NEW)

**Risk: low. This is a live user-visible bug and it is cheap. Do it first of
the behaviour changes.** It was not in v1.

**File:** `Sources/VoiceAIKit/Facade/VoiceIntentSession.swift`

### The defect

`didReceiveFinalResult` launches an unowned, uncancelled task:

```swift
Task { [weak self] in
    guard let self, let engine = self.engine else { return }
    let response = await engine.handle(text)
    self.apply(response, utterance: text)
}
```

`stop()` does not cancel it. And `private var started` (line 63) is **written
twice — `true` at line 154, `false` at line 221 — and never read.** It is a
dead flag.

So: user taps stop while a classification is in flight → the task completes →
`apply` → `announce` → `handleTurnAdvance` → `beginListening()` → **the
microphone reopens after the user stopped the session.** Same failure class as
the mic-permission case in Recommendation #1, strictly cheaper to fix.

### The fix

- [ ] Add `private var classifyTask: Task<Void, Never>?`
- [ ] `didReceiveFinalResult` assigns to it; cancel any prior task first
- [ ] After the `await engine.handle(text)`, re-check before applying:
      `guard !Task.isCancelled, self.started else { return }`
- [ ] `stop()` cancels `classifyTask` (and nils it)
- [ ] **Before writing the guard: enumerate the state machine.** Making a dead
      flag load-bearing fails on the path nobody listed. Write a short table in
      the PR — every writer of `started`, every writer of `state`, and what
      each entry point (`start()`, `startNextListeningTurn()`, `stop()`,
      `reset()`, `classify(text:)`, `hostDidFinishSpeaking()`, the external-TTS
      watchdog) expects to be true on entry. Two bullets below are the
      *expected* answer, not the *researched* one.
- [ ] **Make `started` load-bearing.** Add `guard started else { return }` to
      `handleTurnAdvance()`, and an equivalent early return in
      `beginListening()`. Add a comment stating that `started` is the
      authority on "the host wants this session running", distinct from
      `state`, which tracks where in a turn it is.
- [ ] Confirm `startNextListeningTurn()` is unaffected — it guards
      `state == .idle` and `stop()` sets `.stopped`, so it already refuses

### Tests

- [ ] New: final transcript delivered → `stop()` called before classification
      completes → assert **no** `.stateChanged(.listening)` is emitted
      afterwards and the coordinator is not restarted
- [ ] New: `started == false` after `stop()` blocks `handleTurnAdvance`
- [ ] Full suite green

---

## 4. PR 3 — Surface errors from fire-and-forget Tasks (Recommendation #1) — **corrected**

**Risk: medium.** This is the recommendation v1 rated highest priority, and it
still is — but three of its bullets need changing and one needs deleting.

**File:** `Sources/VoiceAIKit/Facade/VoiceIntentSession.swift`

### 4.1 — Separate task slots, not one `turnTask` (corrected)

v1: "Add a stored `turnTask`… apply the same pattern to `speakSerialized()`…
apply the same pattern to `awaitHostDelivery()`."

A single slot self-destructs. `speakSerialized`'s task is still running when
`speaker.onFinish` → `handleSpeechFinished()` → `handleTurnAdvance()` fires,
so a shared slot has the advance cancelling the speak task that invoked it.

- [ ] `private var listenTask: Task<Void, Never>?` — used by
      `handleTurnAdvance()`
- [ ] `private var speakTask: Task<Void, Never>?` — used by `speakSerialized()`
- [ ] Cancel **both** in `stop()`, alongside `classifyTask` from PR 2

### 4.2 — Do not cancel into `startLiveTranscription()` (new constraint)

v1's snippet cancels the previous task before starting a new one. Verified
against `Core/Coordinator/TranscriptionCoordinator.swift:226`:
**`startLiveTranscription()` is not cancellation-safe.** It walks
`requestingPermissions` → `preparingAudio` → configures the `AVAudioSession`
→ creates and stores `liveProvider`/`activeProvider` → `.transcribing`, with
**no `do`/`catch` teardown on the throw path**. And `TranscriptionState.isActive`
is true only for `.transcribing`/`.processingFile`, so a task cancelled at
`preparingAudio` leaves the coordinator wedged in `.preparingAudio` holding a
configured session and a live provider, while `VoiceIntentSession.state` never
reaches `.listening`.

**PR 3 does NOT close this**, and the PR description must say so. PR 3 stops
cancelling into the coordinator at all, and guards the tail of `beginListening()`
so a microphone that comes up after `stop()` is torn back down. What remains —
two `beginListening()` calls overlapping across a fast stop→start — is a
different problem with its own decision record: **see §7.5**.

### 4.3 — The catch must filter cancellation (new)

v1's snippet yields `.error(message: "\(error)")` for **any** thrown error.
With cancellation in play that emits a bogus
`.error(message: "CancellationError()")` to the host on ordinary turn
transitions.

- [ ] `catch is CancellationError { return }` (and/or `guard !Task.isCancelled`)
      before the yield, in every one of these handlers

### 4.4 — ~~`speakSerialized` needs a state fallback~~ — **WITHDRAWN, the claim was wrong**

This said a failure in the speak task would strand the session in `.speaking`
forever. Checking `ConversationSpeaker` before writing the code: it does not.

`speak()` returns as soon as the utterance is **enqueued** — the continuation
resumes right after `synth.speak(utterance)` — and then `armWatchdog(for:)` runs.
If `didStart` has not fired within 800ms the utterance was silently dropped, and
the watchdog cancels it and calls `onCancel` → `handleSpeechCancelled()` →
`state = .idle`. The strand this task was written to prevent is already
prevented, one layer down, by code that says so in its own comment.

- [x] No change. Left as-is deliberately; adding a second recovery path for the
      same failure is how the surviving one later gets deleted as "redundant".

### 4.5 — Drop the `awaitHostDelivery()` bullet (deleted)

It already has correct invalidation via `hostDeliveryGeneration`, and
`try? await Task.sleep` plus the generation guard already handles
cancellation. Adding a stored, cancelled task gives two mechanisms for one
job — the classic way a later reader removes the "redundant" one that was
actually load-bearing.

- [ ] Leave `awaitHostDelivery()` as-is. Add a one-line comment saying the
      generation counter is deliberate and is the pattern 4.2 Option A reuses.

### 4.6 — Test seam for the acceptance criterion (new)

v1's acceptance test — "a mic permission denial mid-conversation emits an
`.error` event" — is not writable today. Only `.appProvided` audio is
injectable; the `.microphone` path reaches `requestPermissionsOrThrow`
directly.

- [ ] Either add a seam (inject the permission check into
      `TranscriptionCoordinator`) **as an explicit sub-task with its own
      estimate**, or
- [ ] Downgrade it to a documented manual test (revoke mic permission in
      Settings mid-conversation, observe `.error` on `events`) and cover the
      *generic* failure path with a unit test that makes
      `startLiveTranscription` throw

### PR 3 acceptance

- [ ] A failure in the listen path emits exactly one `.error` and leaves the
      session in `.stopped`, never in `.listening`/`.speaking`
- [ ] Normal multi-turn conversation emits **zero** `.error` events
- [ ] Full suite green + manual voice test

---

## 5. PR 4 — `PackStorageController`: drop the recursive lock (Recommendation #9) — **corrected**

**Risk: low-medium.** Mechanical once the call graph is stated correctly.
v1 stated it incorrectly.

**File:** `Sources/VoiceAIKit/OTA/Storage/PackStorageController.swift`

### 5.1 — Option B is deleted, not deferred

v1 offered "convert to an `actor` — cleaner but more work". It is not more
work; it is a **public protocol break**. `PackStorageControlling` is a
`public` `Sendable` protocol with **synchronous** requirements:
`stagingDirectory(for:clean:)`, `currentPack(for:)`, `hasActivePack(for:)`,
`commitStagingAndActivate`, `activate`, `rollback`. An actor cannot satisfy
those without `nonisolated`, so you would have to make the protocol `async`,
which ripples into public `VoiceIntentClient.activePackVersion(for:)`
(currently sync), `STT/Views/PackageVoiceView.swift:70`,
`Tests/.../Mocks/MockPackStorageController.swift`, and any host implementing
the protocol.

- [ ] Take Option A. Do not revisit B without a separate API-break decision.

### 5.2 — The call graph, corrected

v1 said to introduce `_cleanupUnsafe`. **`cleanup(language:activeVersion:)`
does not take the lock at all** — verified, no `lock.lock()` in its body. That
bullet is a no-op, and the class doc comment ("`commitStagingAndActivate`
calls `activate`, which calls `cleanup`, all on one thread") is already stale
about why the lock is recursive.

The actual re-entrant paths are three, not two:

1. public `activate(version:for:)` → private
   `activate(version:for:recordRollbackTarget:)` — **both lock**
2. `commitStagingAndActivate` (locks) → public `activate` (locks)
3. `rollback` (locks) → private `activate(...recordRollbackTarget:)` (locks)

### 5.3 — The change

- [ ] Introduce `private func _activateUnsafe(version:language:recordRollbackTarget:)`
      containing the current private `activate` body **minus** `lock.lock()`
- [ ] Public `activate(version:for:)` becomes the **only** locking wrapper:
      lock → `_activateUnsafe(..., recordRollbackTarget: true)`
- [ ] `commitStagingAndActivate` (already holding the lock) calls
      `_activateUnsafe` directly
- [ ] `rollback` (already holding the lock) calls `_activateUnsafe(...,
      recordRollbackTarget: false)` at both of its two call sites
- [ ] Leave `cleanup` alone; it is called only from `_activateUnsafe` under
      the lock
- [ ] `NSRecursiveLock` → `NSLock`
- [ ] **Rewrite the class doc comment.** It currently justifies the recursive
      lock with a call path that is wrong. Replace it with: which methods
      lock, that `_activateUnsafe` assumes the lock is held, and that
      `currentPack(for:)` remains deliberately lock-free (single atomic
      `rename(2)` symlink swap — keep that paragraph, it is correct and
      load-bearing)

### 5.4 — Tests

- [ ] `PackStorageControllerTests.swift` and `FilesystemStorageTests.swift`
      need no API change — verify they pass unmodified
- [ ] Add: concurrent `activate` + `currentPack` from multiple tasks, assert
      `currentPack` never returns nil mid-swap (guards the lock-free read the
      new comment claims)
- [ ] Add: `rollback` still records the correct target after the refactor
      (the `recordRollbackTarget: false` path is the easiest thing to get
      wrong here — C7)

---

## 6. PR 5 — `NLUPackInstaller` → actor (Recommendation #3) — **corrected**

**Risk: medium.** Its own PR because it changes public API.

**File:** `Sources/VoiceAIKit/OTA/Installer/NLUPackInstaller.swift`

### 6.1 — The false statement, and what replaces it

v1: *"Collapse `claimForActivation()` + `commitActive()` + `markFailed()`
inline into `activatePreparedPack()` — they existed only because lock scope
needed to be narrow; on an actor, the entire method body is serialised."*

**Actor isolation is not mutual exclusion across `await`.**
`activatePreparedPack` suspends at `await engineProvider.smokeTest(...)`, and
a second caller enters the actor there. v1's own later bullet — "a second
`activatePreparedPack` while the first is suspended will see `.validating` and
reject" — is true **only if the guarded state transitions survive**. Inlining
them is precisely how the post-`await` re-check gets dropped, and the failure
mode is two concurrent activations both committing.

- [ ] `public final class NLUPackInstaller: @unchecked Sendable` →
      `public actor NLUPackInstaller`
- [ ] Remove `stateLock` and every `lock()`/`unlock()`
- [ ] `_stagingState` → `public private(set) var stagingState: PackState`
      (drop the computed-property + underscore pattern)
- [ ] **KEEP `claimForActivation()`, `commitActive()` and `markFailed()` as
      private methods.** Keep `guard stagingState == .readyToActivate` in the
      claim and `guard stagingState == .validating` in the commit.
- [ ] Rewrite their doc comments: the guards no longer protect against
      *threads*, they protect against *actor re-entrancy across the smoke
      test's suspension point*. State that explicitly — it is the single most
      losable piece of knowledge in this file.
- [ ] Also re-check the TOKEN GUARD (C8) block's assumptions hold under
      re-entrancy — it reads `staging/bundle.json` after the claim, which is
      still inside the claimed `.validating` window. Confirm and note it.

### 6.2 — Get the blocking work off the actor (new)

`preparePack` holds the lock across `validator.extractAndValidate(...)` —
synchronous unzip plus sha256 over every file in the pack. Under `NSLock`
that blocks the caller's thread. On an actor it blocks a **cooperative pool
thread**, which is worse (the pool is bounded; this is a starvation risk under
concurrent installs).

- [ ] Move `extractAndValidate` into `await Task.detached(priority: .utility) { ... }.value`
      (verified: `PackValidating` and `PackStorageControlling` are already
      `public protocol … : Sendable`, and `PackIdentity` is `Sendable`, so the
      capture and the return value cross isolation without new conformances)
- [ ] Keep the actor for state only. Note that the surrounding state
      transitions (`.downloaded` → `.validating` → `.readyToActivate`) now
      straddle a suspension point, so `preparePack` needs the same
      re-entrancy reasoning as 6.1 — add the guard and the comment

### 6.3 — Public API break: contained, but real

`stagingState` becomes `await`-only. Verified blast radius in this repo:

- `STT/Services/NLUOTAManager.swift` — uses only `preparePack` (line 236) and
  `activatePreparedPack` (line 254), **both already `async`**. No change.
- `VoiceAIKit/docs/ExampleOTAManager.swift` — same two calls. No change.
- `Tests/VoiceAIKitTests/NLUPackInstallerTests.swift` — six reads of
  `installer.stagingState` (lines 22, 38, 48, 79, 126). Need `await`.
- `VoiceIntentClient` holds `public let installer` — actors are `Sendable`, so
  its checked `Sendable` conformance still holds. No change.

- [ ] Update the five test assertions to `await installer.stagingState`
- [ ] **`VoiceAIKit/docs/ExampleOTAManager.swift` is in no SwiftPM target**, so
      nothing compiles it and it will rot silently against the new API. Read it
      by hand after the change and update it — it is the sample every
      integrating host copies from
- [ ] **Add a CHANGELOG / `PUBLIC_API_PLAN.md` entry.** v1's Phase 2 note "all
      `internal` types, so no public API impact" is true of Phase 2 and false
      here: this is source-breaking for any external host that reads
      `stagingState`.
- [ ] Rewrite the class doc comment — it currently says state "is guarded by
      the internal `stateLock` below" and that "`preparePack`/
      `activatePreparedPack` do no `await` inside the critical section", both
      of which 6.1/6.2 make false

---

## 7. Phase 4 — split, re-scoped, and one open decision

v1 priced 4.1/4.2/4.3 as "1–2 days" together. 4.1 alone is that.

### 7.1 — PR 6: extract `AssetManager` (Recommendation #2, part) — **do it**

This half of v1's task 4.1 is genuinely easy: model-asset installation and
locale resolution share nothing with the recognition loop except two static
caches that move with them.

- [ ] Create `Core/Recognition/AssetManager.swift` with
      `ensureModelInstalled(for:locale:)`, `logModelStorageLocation(for:)`,
      `resolveTranscriberLocale(_:)`, the `verifiedLocaleAssets` /
      `localeResolutionCache` statics, and the `buildOffMain(_:)` helper
- [ ] **Decide type-vs-extension explicitly and write the decision in the PR.**
      Swift's `private` is **file-scoped**: an `extension SpeechRecognitionService`
      in a new file cannot see the original file's `private` members. For this
      slice that is survivable (these methods touch little private state), but
      make it a conscious call, not a discovery at compile time.
- [ ] Preserve `@MainActor` isolation; `buildOffMain` stays `nonisolated static`
- [ ] Full suite green

### 7.2 — Deferred: endpointing extraction (Recommendation #2, rest) — **needs design first**

v1 called this "move `shouldEndpointFor…`, `commitStableTranscriptAsFinal`,
and all endpointing state into `EndpointController.swift`." Two blockers:

1. **`private` is file-scoped.** The endpointing methods touch ~10 private
   stored properties (`lastPartialText`, `lastPartialChangeAt`,
   `finalizedTranscript`, `firstSpeechAt`, `didSynthesizeFinal`,
   `hasVolatileText`, `hasReceivedFinalResult`, `arbitratedText`,
   `arbitratedVerdict`). As an extension-in-a-new-file, every one widens to
   `internal` — trading a 1,000-line file for a weaker encapsulation boundary
   across the whole module. Net negative. As a **new type**, the feed loop's
   main-actor hops (lines ~358, ~471) now call through
   `self.endpointController`, which is a real change to the hot path.
2. **Naming collision.** `Core/Recognition/EndpointDecider.swift` already
   exists and already *is* the extracted endpointing logic — pure, clock-free,
   injectable, with `EndpointDeciderTests`. A sibling `EndpointController` one
   word away is a trap.

- [ ] Write a short ADR before writing code: new type or extension; if a new
      type, what it is called (`EndpointingSession`? does it *hold* an
      `EndpointDecider`?) and who owns the clock
- [ ] Frame the goal as "extend the `EndpointDecider` pattern to cover the
      remaining stateful half", not "split a big file"
- [ ] Schedule as its own sprint item

### 7.3 — Proposed won't-do: eliminate `NLUSchema` (Recommendation #10) — **needs your sign-off**

> This is the one item in the plan where an engineering *recommendation* is
> being substituted for a *decision that is yours*. The reasoning below is
> strong but it is an argument, not a finding. Sign it off or overrule it
> before PR 1 merges, so the §2.3 file placement matches the outcome.


`PackEngineFactory.schema(from:)` is **not** a translation method. It is the
join between the pack's structure and its per-language response catalog:
`pack.responses[slot.prompt]`, the `sys.confirm.cancelled` default, the
`workflow.confirmation` → `FollowupDef` mapping, `workflow.completion` →
`fulfillment`. Deleting it moves that join **into** `NLUEngine`, coupling the
engine to the on-disk pack format — the exact coupling `DialogSchema.swift`'s
own header says the type exists to prevent. `NLUSchema` is an anti-corruption
layer, not an intermediate type.

v1's audit list is also incomplete: `version` is read, and `IntentDef`'s
fields are *resolved* strings, not pack values, so "make `NLUEngine` accept a
`ResolvedPack` directly" is not a substitution — it is a relocation of real
work into the engine.

- [ ] **Decision needed (owner: Akash):** close #10 as won't-do, or overrule
      and schedule it. If closed, record the reasoning above in
      `BUG_TRACKER.md` / `TODO.md` so it is not re-proposed next quarter
- [ ] The legitimate irritation behind it — "why are there two shapes?" — is
      answered by §2.3's move of `DialogSchema.swift` into `Pack/Loader/`,
      next to the factory that builds it. If more is wanted, rename the types
      to say what they are (`DialogTables` etc.) in a separate cosmetic PR

### 7.4 — Revised: `nonisolated(unsafe)` in the audio feed (Recommendation #8) — **inverted**

v1: "Encapsulate all `nonisolated(unsafe)` bindings (`feedStream`,
`feedConverter`, `feedVAD`, `feedFormat`, `feedBuilder`) as **stored
properties** of this type."

That makes the safety argument **weaker**. Today those five are *locals*
inside `startTranscribing` (lines 342–346), created in the parent scope and
consumed by exactly one child task — the strongest available form, because no
sharing is even expressible. As stored properties of a long-lived object they
become reachable from anywhere holding that object, force `@unchecked
Sendable` on the new type, and replace a structural guarantee with a comment.

Also, the task covers 5 of ~8 `nonisolated(unsafe)` sites: lines 184, 192,
292, 298 and 903 are prewarm/asset-path bindings and stay. "Concentrates the
unsafe surface area" is therefore partial — say so in the PR rather than
implying the count goes to one.

- [ ] If done: pass the five **by value** into a `nonisolated` function (or a
      non-escaping struct created and consumed in the same scope), so the
      "created here, consumed once, never shared" argument is preserved
- [ ] Do **not** promote them to stored properties
- [ ] Document the safety argument in one place — that part of v1 was right
- [ ] Low priority; ship after 7.2

---

### 7.5 — Overlapping turns: generation tag vs serialized turn chain

**Status: decision record, no code. Its own PR when scheduled.**

#### The problem

`started` is a `Bool`. It answers "does the host want a session running *now*".
It cannot answer "does the host want *this* session run" — and after PR 3 that is
the only question left that matters.

`coordinator.startLiveTranscription()` is ~60ms of real work (`micStart phase
sessionConfigure: 61ms` in a device log). Inside that window:

| t | what happens | `started` |
|---|---|---|
| 0ms | turn advance → `beginListening()`, mic starting | `true` |
| 20ms | user taps **stop** → `markNotRunning()` | `false` |
| 40ms | user taps **start** → a second `beginListening()` begins | `true` again |
| 60ms | the FIRST task finishes and reaches its `guard started` | `true` |

The first task reads `true`, concludes it is still wanted, and sets
`state = .listening` — for a session run the user stopped. Two
`startLiveTranscription()` calls have now run. The coordinator's own
`guard !state.isActive` only catches the second if the first already reached
`.transcribing`; at `.preparingAudio` both proceed and two providers are created.

The guard is not lying. It has no way to ask the question it needs to ask.

#### Option 1 — generation tag (RECOMMENDED)

Replace the yes/no reading with an identity. An `Int` bumped by every `start()`
and `stop()`; each task captures it at launch and compares before acting.

    task launches  → captured generation 7
    stop + start   → generation is now 9
    task finishes  → 7 != 9 → this run was abandoned, return

- **Precedent in this very file.** `hostDeliveryGeneration` (~line 85) already
  does exactly this for the external-TTS watchdog, and works.
- No ordering change, no added latency, no new failure mode.
- Small enough to revert cleanly.
- Closes the problem completely: every task carries its own identity, so a stale
  one always removes itself.

#### Option 2 — serialized turn chain

One `Task` per session; every advance enqueues onto it and awaits its
predecessor, so two `beginListening()` calls cannot overlap by construction.

Genuinely the cleaner architecture, and it subsumes Option 1 — but three costs,
all real, and the first is disqualifying until it is designed around:

1. **Self-deadlock on an existing path.** If classification runs on the chain
   then `apply()` runs on the chain, and `apply()`'s `.fallback` branch calls
   `handleTurnAdvance()` **directly** — which would enqueue a task that awaits
   the currently-running chain task. `finishTurnIfNeeded()` and
   `handleSpeechFinished()` reach `handleTurnAdvance()` the same way. All three
   need rewriting first, or a `.notUnderstood` turn jams the session forever —
   a worse bug than the one being fixed.
2. **Latency, in a codebase that measures it.** Serialising adds waiting exactly
   where this team has spent effort removing it: `ConversationSpeaker` sets
   `postUtteranceDelay = 0` with a comment that 100ms there "added a flat 100ms
   between the prompt ending and `didFinish` → mic restart on every conversation
   turn". A user who hears the prompt end and starts speaking before the mic is
   open is a real product defect.
3. **It does not cover the public entry points on its own.** `start()` and
   `startNextListeningTurn()` call `beginListening()` directly. The chain fixes
   advance-vs-advance; advance-vs-start needs `start()` to drain the chain
   first, and start-vs-start still needs a guard. So the complete answer is the
   chain PLUS something at the entry points — which is Option 1 again.

#### Option 3 — make `startLiveTranscription()` cancellation-safe (orthogonal)

Wrap its body so a throw or cancellation tears the partial setup down and
returns the coordinator to `.idle`. This does not fix overlap by itself, but it
removes the reason PR 3 refuses to cancel anything, and it is worth doing on its
own merits: today a throw mid-start leaves the coordinator in `.preparingAudio`
holding a configured audio session. Independent of 1 and 2.

#### Recommendation

**Option 1 now. Option 3 when the coordinator is next touched. Option 2 only as
a deliberate architectural project, with the three call sites in cost (1)
rewritten first.**

An earlier draft of this plan called Option 2 "the actual fix" and Option 1 "a
mitigation". That was wrong, and the reversal is the useful part of this record:
the generation tag does not narrow the window, it closes it — a task that knows
which run it belongs to can always disqualify itself. Option 2 is a broader
improvement that happens to include this one, not a stronger fix for it.

#### How to verify either

The window is ~60ms, so do not try to hit it by hand. Widen it: a temporary
`try? await Task.sleep(for: .seconds(3))` inside `beginListening()` before
`coordinator.startLiveTranscription()`, then stop→start inside those 3 seconds.
Before: two `startTranscribing called` lines in the log for one session, and
`state` ending on `.listening` from the abandoned run. After: the first task logs
that it was superseded and returns.

---

## 8. Traceability — v1 → v2

| v1 task | Recommendation | Disposition in v2 |
|---|---|---|
| 1.1 Move `VoiceIntentClient` | #5 | PR 1 §2.1 — unchanged |
| 1.2 Move `MemoryProbe` | #6 | PR 1 §2.2 — unchanged |
| 1.3 Delete `resolveLocale` | #7 | PR 1 §2.5 — **grep rescoped**; delete, don't deprecate |
| 2.1 `Data/` → `Pack/` | #4 | PR 1 §2.3 — `DialogSchema` refiled to `Loader/` |
| 2.2 `NLUCore/` → `Engine/` | #4 | PR 1 §2.4 — unchanged |
| — | — | **PR 2 §3 — NEW: `stop()` mic-reopen bug, dead `started` flag** |
| 3.1 Fire-and-forget tasks | #1 | PR 3 §4 — split task slots; no cancel into `startLiveTranscription`; filter `CancellationError`; state fallback; watchdog bullet dropped; test seam called out |
| 3.2 Installer → actor | #3 | PR 5 §6 — **"inline the critical sections" reversed**; blocking work detached; API break documented |
| 3.3 `NSRecursiveLock` | #9 | PR 4 §5 — call graph corrected (3 paths, not 2); `cleanup` bullet dropped; **Option B deleted** |
| 4.1 Split `SpeechRecognitionService` | #2 | Split: **7.1 do now** (AssetManager) / **7.2 deferred, needs ADR** (endpointing) |
| 4.2 Extract `AudioFeedPipeline` | #8 | 7.4 — **approach inverted**: by value, not stored properties |
| 4.3 Eliminate `NLUSchema` | #10 | 7.3 — **proposed won't-do, awaiting sign-off** |

---

## 9. Order and risk

| # | PR | Risk | Gate |
|---|---|---|---|
| 0 | §1 Preflight — clean tree, runner check, CI workflow, app-tree scope call | 🟢 none | Must merge CI before PR 2 |
| 1 | §2 Structural moves (#4 #5 #6 #7) | 🟢 none | Build + baseline suite |
| 2 | §3 `stop()` lifecycle bug | 🟢 low | New regression test |
| 3 | §4 Turn-task error surfacing (#1) | 🟡 medium | Manual voice test |
| 4 | §5 `PackStorageController` lock (#9) | 🟡 low-med | Concurrency test |
| 5 | §6 Installer actor (#3) | 🟡 medium | CHANGELOG entry; API note |
| 6 | §7.1 `AssetManager` (#2 part) | 🟡 medium | Full suite |
| — | §7.2 Endpointing (#2 rest) | 🟠 high | **ADR first** |
| — | §7.4 Audio feed (#8) | 🟠 med-high | After 7.2 |
| — | §7.3 `NLUSchema` (#10) | — | **Decision pending** |

Rollback: PRs 1–6 are independently revertible with `git revert`. PR 1's moves
revert cleanly because they carry no content edits (§2.0).

### Effort, honestly

- Preflight: half a day (mostly the CI workflow)
- PR 1: half a day
- PR 2: 2 hours
- PR 3: 1 day if 4.6 stays manual; 2 if the permission seam is built
- PR 4: half a day
- PR 5: half a day, plus review time for the API note
- PR 6: 1 day
- 7.2 + 7.4: a sprint, after the ADR

v1's "Phase 3: 3–4 hours" and "Phase 4: 1–2 days" were both optimistic by
roughly a factor of three.
