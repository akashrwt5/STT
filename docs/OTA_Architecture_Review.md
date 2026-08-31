# VoiceAIKit OTA Subsystem — Architecture Review

**Reviewer perspective:** Principal Architect (on-device NLU / voice assistant platforms — Siri / Alexa class)
**Scope:** OTA update path for the on-device NLU packs — SDK (`VoiceAIKit`) and host orchestration (`STT`)
**Date:** 2026-08-12

**Files reviewed**

- `STT/Services/NLUOTAManager.swift` — host-side orchestrator (`actor`)
- `VoiceAIKit/OTA/Installer/NLUPackInstaller.swift`
- `VoiceAIKit/OTA/Validation/PackValidator.swift`
- `VoiceAIKit/OTA/Storage/PackStorageController.swift`
- `VoiceAIKit/OTA/Models/{NLUPackManifest,PackState}.swift`
- `VoiceAIKit/VoiceIntentClient.swift`, `Facade/PackProvider.swift`
- `docs/nlu_ota_client_architecture.md`, `docs/BackgroundOTAIntegration.md`, `docs/ExampleOTAManager.swift`

---

## 1. Executive summary

The overall shape is sound and shows real platform maturity: a thin SDK that never opens a socket, a host that owns networking and background scheduling, a staging→validate→smoke-test→atomic-activate lifecycle, a symlink-as-source-of-truth storage model with rollback, and dependency injection almost everywhere. For a v1 this is a good skeleton and the separation of concerns document is above average.

However, the code is **not yet safe to ship as the trust-and-safety-critical path it claims to be**, for two categories of reason:

1. **The concurrency safety model is asserted, not enforced.** Multiple files carry a comment stating that mutable state "is protected by the upstream `NLUOTAManager` actor's serialization." That claim is incorrect. The classes it protects are also reachable directly from the host app and the live inference engine, on other threads, with no synchronization. `@unchecked Sendable` then switches off the one compiler check that would have caught it. There are concrete data races on `stagingState`, `preparedManifest`, and — most seriously — on the `Packs/{lang}/` filesystem itself.

2. **The trust chain is advertised but off by default.** Signature verification is bypassed when the trusted key is `nil` (the default), checksum verification is an empty stub, and a download size mismatch only logs a warning and proceeds. So in the shipping default configuration an OTA pack is installed with *no* authenticity or integrity check. For a remotely-delivered on-device model this is a supply-chain exposure, not a nice-to-have.

Neither is a rewrite. Both are a focused hardening pass. The rest of this document is the prioritized list.

Severity legend: **[P0]** ship-blocker · **[P1]** fix before GA · **[P2]** important · **[P3]** polish.

---

## 2. Concurrency / multithreading

### [P0] C1 — The "actor serializes the shared class" guarantee is false

`NLUPackInstaller` and `VoiceIntentClient` are both `final class ... @unchecked Sendable`, each carrying:

> *Thread Safety: This class is designed to be accessed through a single `NLUOTAManager` actor. Its mutable state is protected by the upstream actor's serialization.*

An `actor` serializes access to **its own** isolated state. It does **not** serialize access to a reference-type object it happens to hold, when that same object is *also* referenced elsewhere. And it is:

- `VoiceIntentClient` is created and owned by the **host app**, which calls `start(for:)`, `activePackVersion(for:)` and reads `isEngineIdle` directly (see `ExampleOTAManager` / integration docs) — not through the actor.
- The **live inference engine** reads/writes `isIdle` on the audio/inference thread.
- `NLUOTAManager` calls into the *same* `installer` / `voiceClient` from the OTA task.

So the same instances are touched from at least three execution contexts concurrently. `stagingState` (`public private(set) var`) and `preparedManifest` are plain stored properties mutated inside `preparePack` / `activatePreparedPack` with no lock — a UI layer observing `stagingState` while the installer writes it is a textbook data race, and TSan/Swift strict-concurrency will flag it the moment `@unchecked` is removed.

**Fix:** make the isolation real, don't assert it. Either (a) convert `NLUPackInstaller` itself to an `actor` and make the engine an `actor`/isolated type, or (b) if it must stay a class, guard every mutable field with a single internal `OSAllocatedUnfairLock`/`DispatchQueue` and drop `@unchecked Sendable` in favor of genuine `Sendable`. Do not keep `@unchecked` with a prose promise — that is exactly the pattern that hides races.

### [P0] C2 — `isIdle` gate is a TOCTOU race; nothing actually locks the engine for activation

The entire safety story is "wait until the engine is idle, then swap the model." Today that is a check-then-act with no mutual exclusion:

1. `NLUOTAManager` loops `while !voiceClient.isEngineIdle { sleep(1s) }`.
2. `activatePreparedPack` independently re-checks `guard engineProvider.isIdle`.
3. Then it smoke-tests, then `commitStagingAndActivate` mutates the filesystem.

Between step 2 and the filesystem swap — and for the whole duration of the swap — a new wake-word / voice session can start on the audio thread. Nothing holds a lock that transitions the engine *atomically* from "idle" to "locked for activation." On a Siri/Alexa-class device, barge-in during activation is not a rare edge — it is the expected case.

Additionally, `engineProvider.isIdle` is an unsynchronized `Bool` read across threads (protocol declares `var isIdle: Bool { get }` with no isolation/`Sendable`), so there is no defined memory-visibility guarantee that the OTA thread even observes the latest value.

**Fix:** introduce an explicit lease the engine hands out — e.g. `func acquireActivationLock() -> Bool` / `withActivationLock { … }` on the engine, or model the engine as an actor with an `activate(...)` message that is serialized against inference on the same executor. The idle *check* must be fused with the *hold* so no session can start between them. Poll-until-idle is fine for scheduling, but the final transition needs a real lock, not two independent reads.

### [P0] C3 — Cross-entry-point filesystem race on `Packs/{lang}/`

`PackStorageController` is a plain `final class` with **no internal synchronization**, and it is mutated from two unrelated flows:

- Host launch / language switch → `VoiceIntentClient.start()` → `storage.rollback()` → `activate()` (symlink swap) → `cleanup()` (deletes version dirs).
- OTA task → `installer.activatePreparedPack()` → `storage.commitStagingAndActivate()` → `activate()` → `cleanup()`.

If a background OTA activation overlaps a launch-time `start()`/rollback for the same language, two writers are simultaneously (a) moving `staging`→version dir, (b) deleting version dirs in `cleanup`, and (c) doing the remove-then-move `Current` symlink dance. Concrete failure modes: `cleanup` deletes a version dir that the other flow is mid-`activate` on (`versionDirectoryNotFound`), or both create/move `Current` and one throws. The "single actor serializes everything" assumption (C1) is what was supposed to prevent this, and it doesn't hold because `start()` bypasses the actor entirely.

**Fix:** serialize *all* mutations of a language directory through one owner. Practical option: make `PackStorageController` an `actor` (or wrap each language dir in a per-language serial queue / lock keyed by language). Every `activate`/`rollback`/`cleanup`/`commit` for a given language must run under that one lock.

### [P1] C4 — The `Current` symlink swap is not actually atomic

`activate(version:)` does `removeItem(Current)` **then** `moveItem(temp → Current)`. There is a window between the remove and the move where `Current` does not exist: a concurrent reader (`currentPack`) returns `nil` and the app silently treats the device as having no active pack (falls back to seed), and a crash in that window leaves no `Current` at all. Foundation's `moveItem` refuses to overwrite, which is why the code deletes first — but that defeats atomicity.

**Fix:** use the POSIX `rename(2)` syscall directly (`rename(tempLink, currentLink)`), which atomically replaces the destination. That is the standard atomic-symlink-swap idiom and removes the gap entirely. (`replaceItemAt` is correctly avoided here because it resolves the link; `rename` on the link path is what you want.)

### [P1] C5 — Activation mutates disk but never reloads the live engine (advertised "hot-swap" is missing)

`activatePreparedPack` runs a smoke test on the new model and swaps the filesystem, but it never calls `engineProvider.load(...)`. So after a "successful" activation the **running** engine keeps serving the *old* model until the next process launch calls `start()`. Two consequences:

- The `PackProvider` header comment advertises "verifies, loads, binds and — later — hot-swaps"; there is no hot-swap. This is a functional gap, and it makes the whole idle-gate ceremony questionable: if you are not touching the running engine, why require idle at all? The likely intent was to reload live — and *that* missing step is exactly where the C2 race would bite, so it must be added carefully under the C2 lock.
- It should be stated explicitly in the design whether activation is "apply on next launch" or "apply now." Right now the code does the former while the docs imply the latter.

**Fix:** decide the semantics. If hot-swap is intended, add an engine `reload()` performed under the activation lock (C2), immediately after `commitStagingAndActivate`, with rollback if the reload throws. If apply-on-next-launch is intended, drop the idle-wait from the activation path and document it.

### [P1] C6 — Corrupted OTA pack with no previous version defeats the seed-pack safety net

In `VoiceIntentClient.attemptLoadActivePack`, on a corrupt bundle it calls `try storage.rollback(...)` **unguarded**. If there is no previous version, `rollback` throws `noPreviousVersionAvailable`, which propagates out of `attemptLoadActivePack` → out of `start()`. The `if !didLoadActive { loadSeedPack() }` fallback is never reached. Net effect: a single bad OTA pack (with no prior version) bricks engine startup even though a known-good seed pack is bundled — the exact scenario the seed pack exists to cover.

**Fix:** treat rollback failure as "no active pack loaded" and fall through to the seed pack: wrap the rollback/retry in a `do/catch` that returns `false` so `start()` proceeds to `loadSeedPack`. The seed pack should be the guaranteed floor and nothing in the OTA path should be able to throw past it.

### [P2] C7 — Rollback selects "highest other version," not "last known-good"

`rollback` picks `versions.filter { $0 != current }.last` — the numerically highest *other* version. It has no notion of which version was previously active or which is known-good. With today's retention (keep active + immediately previous) `cleanup` usually deletes the bad version so this self-heals, but the selection semantics are still wrong: if retention is ever widened, or if the highest remaining version *is* a bad one you rolled away from earlier, rollback can re-activate the bad pack. Rollback should be driven by an explicit "last known-good" marker, not by version ordering.

**Fix:** persist a small ordered "known-good" list (or a `previousGood` pointer) as part of the atomic activation, and roll back to that, not to `sorted().last`.

### [P2] C8 — Cancellation leaves installer state and disk briefly divergent

If the OTA task is cancelled during the idle-wait, `preparePack` has already set `stagingState = .readyToActivate` and cached `preparedManifest`, but activation never runs. The next `preparePack` wipes staging (`clean: true`) and resets state, so it self-corrects for the single-caller case — but the state machine does not *defend* the invariant. If a second `activatePreparedPack` (from app code, per C1) fires against a stale `readyToActivate` after staging was rebuilt, it operates on mismatched state.

**Fix:** once the installer is properly isolated (C1), make the prepared state carry an identity (e.g. the staging dir's version + a token) and have `activatePreparedPack` validate that the on-disk staging still matches the token before committing.

---

## 3. Security / trust chain (bundled here because it is also a correctness gap)

### [P0] S1 — Signature verification is bypassed by default

`PackValidator.verifySignature` early-returns when `trustedPublicKeyBase64 == nil`, and the initializer defaults that parameter to `nil`. The `TODO: (Security)` acknowledges it. So unless the host explicitly injects a key, **no Ed25519 verification happens** — while the docs and the `PackProvider` header both advertise "the ed25519 + sha256 trust chain" as the SDK's core value.

### [P0] S2 — Checksum verification is an empty stub

`verifyChecksums` is a no-op with a comment describing what it *would* do. The seed pack ships an `integrity/manifest.sha256`, so the data to verify against exists; the code just doesn't. Combined with S1, an installed pack has neither authenticity nor integrity checking in the default build.

### [P1] S3 — Size mismatch is ignored, and it "relies on SDK crypto validation" that doesn't run

`NLUOTAManager` logs *"Download size mismatch … Proceeding anyway, relying on SDK crypto validation"* — but per S1/S2 that validation is off. The one cheap integrity signal available at the network layer is discarded, and it defers to a check that is a stub. `config.urlCache = nil` plus automatic redirect-following to object storage means a compromised BFF or a MITM on the redirect can serve an arbitrary model with no gate.

**Fix (S1–S3):** make signature verification **mandatory** — the key should be a required init parameter (or embedded compile-time constant), and a missing/malformed key should be a hard failure, never a bypass. Implement `verifyChecksums` against `integrity/manifest.sha256` before the pack is ever marked `readyToActivate`. Treat a size mismatch as a hard failure. Verification must gate activation, not merely log.

### [P3] S4 — Dev artifacts leaking toward the product path

`ngrok-skip-browser-warning: true`, `key_id: "dev-key-golden"`, and ngrok-style BFF hosting are development conveniences appearing in the shipping orchestrator. Fine for now; make sure they are environment-gated before GA.

---

## 4. SOLID assessment

**Single Responsibility — partial.**
`NLUOTAManager` is doing a lot: BFF polling, JSON decoding, download, size sanity check, temp-file cleanup, prepare, idle-timing loop, activation, and telemetry timing. It reads as a God-orchestrator. Splitting a `BFFUpdateClient` (poll + download + decode) from an `ActivationCoordinator` (prepare → idle-lease → activate) would make each independently testable. `PackStorageController` similarly bundles *mechanism* (layout, atomic swap) with *policy* (`cleanup` = "keep active + 1"). Retention is a product policy and should be an injected `RetentionPolicy`, not hardcoded inside the storage primitive. `PackValidator` bundles extraction orchestration + manifest parsing + signature + checksums + model-existence — four reasons to change; consider `ManifestParser`, `SignatureVerifier`, `ChecksumVerifier` behind the one `PackValidating` facade.

**Open/Closed — weak spot in model resolution.**
`NLUPackManifest.resolveModelPaths` hardcodes `models["intent"]` and CoreML-only. The manifest structure and the seed pack both carry a `semantic_head` model, which this path can never resolve, load, or smoke-test — adding a second model head requires editing the resolver rather than extending it. Consider a `resolveModelPaths(components:)` that iterates the declared model components so new heads are additive.

**Liskov — good.** The protocol seams (`PackStorageControlling`, `PackValidating`, `PackExtractor`, `NLUEngineProvider`, `PackProvider`) are clean and substitutable; `StaticPackProvider` and the test mocks are honest implementations. No LSP violations spotted.

**Interface Segregation — minor.**
`NLUEngineProvider` fuses model lifecycle (`smokeTest`, `load`) with a liveness/concurrency signal (`isIdle`); a caller that only needs idle-state drags in load/smoke-test. `PackStorageControlling` is broad (7 methods) with overlapping `commitStagingAndActivate` vs `activate`; the installer needs staging+commit, the client needs current/hasActive, rollback is a third concern. Splitting into `PackReading` / `PackActivating` / `PackRollback` would tighten dependencies.

**Dependency Inversion — the strongest area.** High-level flows depend on protocols and inject extractor/validator/storage/engine. Two leaks worth closing: (1) `VoiceIntentClient.attemptLoadActivePack` uses `FileManager.default` directly while `PackStorageController` uses an injected `fileManager` — inconsistent, and it means a test that injects a fake FileManager into storage won't affect this code path; route it through storage. (2) Manifest loading (`Data(contentsOf:)` + `JSONDecoder`) is duplicated inline in `VoiceIntentClient` and elsewhere; a single injected `ManifestLoader` would remove the duplication and the concrete-dependency.

---

## 5. Design-coherence notes

**`PackProvider` looks like a half-landed migration.** `Facade/PackProvider.swift` describes, at length, replacing `LanguagePackRegistry` with a host-supplied `packURL(for:)`. But `VoiceIntentClient` still takes a raw `seedPackURL: URL` and reads `storage.currentPack` directly — it never consumes a `PackProvider`. So there are effectively two competing abstractions for "where do the bytes come from," and only one is wired in. Either finish routing `VoiceIntentClient` through `PackProvider` or mark it clearly as future/unused, so the next engineer doesn't assume it is the live path.

**Observability inconsistency.** `PackValidator` uses `print()` for a security-relevant warning while everything else uses `os.Logger`. Route it through `Logger` (and, given S1, it should be an error/fault, not a print).

**Silent `try?` swallowing.** `currentPack` and `cleanup` swallow errors with `try?`, so a permissions failure is indistinguishable from "no pack," and a failed cleanup silently accretes disk. Acceptable for v1, but at least log at debug so field diagnostics are possible.

**Per-call decode cost.** `activePackVersion` re-reads and decodes `bundle.json` on every call, and it is called on each OTA check and potentially from UI. Cache the active manifest and invalidate on activation.

---

## 6. Suggested priority order

1. **S1 + S2 + S3** — make signature + checksum verification mandatory and gating; stop ignoring size mismatch. (Trust chain.)
2. **C1 + C2 + C3** — replace the "actor protects the class" assertion with real isolation: isolate the installer/engine, fuse the idle-check with an activation lease, and serialize all `Packs/{lang}` mutations. Remove `@unchecked Sendable` and let strict concurrency / TSan verify.
3. **C6** — guarantee the seed-pack floor: no OTA rollback failure may throw past `start()`.
4. **C4 + C5** — atomic `rename(2)` symlink swap; decide and implement the activation-vs-live-engine semantics (hot-swap under lock, or apply-on-next-launch).
5. **C7 + C8** — known-good rollback marker; token-guarded prepared state.
6. **SOLID / coherence** — extract `BFFUpdateClient`, injected `RetentionPolicy`, `resolveModelPaths(components:)`, finish or retire `PackProvider`.

## 7. How I'd verify the fixes

- Turn on `-strict-concurrency=complete` and **delete `@unchecked Sendable`**; the remaining diagnostics are the real race surface.
- Add a ThreadSanitizer test that drives `start(for:)` on one task and `activatePreparedPack` on another against the same language dir, asserting no TSan report and a consistent final `Current`.
- A barge-in test: signal the engine busy the instant after the idle check and assert activation cannot proceed (proves C2's lease).
- A trust test: feed a pack with a tampered `bundle.json` / bad signature / wrong checksum and assert `extractAndValidate` throws and the pack is never marked `readyToActivate`.
- A "bad-pack-no-previous" test: corrupt the only OTA pack and assert `start()` loads the seed pack rather than throwing (proves C6).
