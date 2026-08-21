# VoiceAIKit — readiness to link into a client app other than STT

**Question asked:** can we add the package to the ClientApp (Engage / PVA), not just STT?
**Assessed:** 21 Aug 2026, branch `fix/ota-unification-and-concurrency`, pack `pack-en-v1.0.36-ios`.
**Method:** static read of `VoiceAIKit/`, the STT host wiring, and `docs/pva-integration/*` (the normative SPEC). No build — this environment has no Xcode, so nothing here is compile- or device-verified.

---

## Verdict

**Architecturally yes. Mechanically not yet — four hard blockers, and none of them are in the NLU.**

The shape is right, and it is right for the reasons that usually get skipped. The library ships zero data and the acceptance test for that is the absence of a `resources:` block in `Package.swift`. The pack is supplied by the host through `PackProvider`, never discovered. The trust chain verifies before it parses, and the canonicalisation rule is documented where someone will actually read it. A wrong-language or unverifiable pack throws instead of degrading to English — which, for a hearing aid, is the only defensible answer. `.appProvided` audio and `speaksPrompts: false` already implement D1 and D4 of ADR-0001 before the adapter exists.

What is not ready is everything around the code: the platform floor, the signing keys, the distribution, and the App Store paperwork. Those are all tractable. Estimate: **~1 week of package work, plus the Engage adapter**, with two pack-contract items I would hold GA on.

---

> **Update, 21 Aug 2026 — after review with Akash.** B1 and B3 are settled, B4 is done. The verdict above stands, minus those three. Live blocker list is now **B2 only**, plus the contract gaps (C1, C2) and hygiene (H1–H8). The original text of B1/B3/B4 is kept below with its resolution, so the reasoning is still auditable.

## Hard blockers

### ~~B1 — The iOS 26 floor is a whole-package floor~~ — **ACCEPTED, not a blocker**

**Resolution:** the client app's own minimum is iOS 26, so the package floor costs nothing. No target split. Revisit only if a host with a lower floor appears — the split described below is still the answer if one does.

*Original finding:*

`Package.swift` declares `platforms: [.iOS("26.0")]`, and there is **not one `@available` annotation in the entire `Sources/VoiceAIKit` tree** (grep: 0 hits). So the NLU half — pack loading, TF-IDF/CoreML classifier, entity extraction, dialog manager, none of which needs anything newer than CoreML — is dragged to iOS 26 by `SpeechAnalyzer`/`SpeechTranscriber` in `Core/Recognition`. Any app that *links* the product must raise its deployment target to 26.0; SwiftPM refuses otherwise. Remote-config provider selection cannot save you here, because linking happens before any runtime check.

STT gets away with it (`IPHONEOS_DEPLOYMENT_TARGET = 26.2`). Engage will not.

**Fix:** split the targets — `VoiceIntentNLU` (pack + classifier + dialog + `classify(text:)`, iOS 17-ish floor) and `VoiceIntentSpeech` (iOS 26, depends on NLU), with `VoiceAIKit` as the umbrella. Then Engage links at its real floor, the Dialogflow provider serves everyone, and the on-device ASR provider activates only on iOS 26+ hardware. Second-best: `@available(iOS 26, *)` on the Speech types and drop the platform floor — cheaper, but leaves a package whose public surface is half-unavailable.

### B2 — No production trust policy exists anywhere

`PackIntegrity.swift` is the best-argued file in the package, and every call site defeats it:

- `STTApp.swift:38` — `STTNLUEngineProvider.trust = .unverifiedForTesting`
- `STTApp.swift:139` — `PackValidator(extractor:trust: .unverifiedForTesting)`
- `PackageVoiceView.swift:52` — `PackProviderForApp.trust = .unverifiedForTesting`

`.unverifiedForTesting` sets `skipsSignatureVerification: true, refusesDevelopmentPacks: false`. Ship that into a client app and a compromised CDN or a MITM on the BFF puts an attacker-authored pack in front of a hearing-aid command path. The size check and sha256 manifest do not help: the manifest is inside the pack.

`VoiceAIKit/TODO.md` already carries this as the top security item. Needed before any client-app link: an Ed25519 production keypair with a `key_id`, the compiler signing with it, a rotation story, and a release policy of `refusesDevelopmentPacks: true` with `skipsSignatureVerification: false` — enforced by something other than a code review (a `#if !DEBUG` assertion in the host, or a policy factory that cannot construct the dev policy in a release build).

### ~~B3 — No distribution story~~ — **DECIDED: shared as a local package**

**Resolution:** the client app takes it as a local package, same as STT. That removes the repo/tagging question and keeps the source in one place. Two consequences to accept deliberately: there is no version pin, so a package change lands in both hosts the moment it is checked out — the CI surface guard in `PUBLIC_API_PLAN.md` §7 becomes the substitute for semver; and both hosts must build from the same checkout, so the copy the client app links needs a defined sync mechanism (submodule, subtree, or a shared parent directory) rather than a manual copy, which drifts silently.

The hygiene items stand regardless:
- `VoiceAIKit/.build/workspace-state.json` is **tracked in git** despite `.gitignore`.
- Six `.DS_Store` files live under `Sources/VoiceIntentSeedPackEN/packs`, which is `.copy`'d verbatim — they ship inside the client app's bundle. (`PackLoadPolicy.ignoredFileNames` tolerates them at load; that is not a reason to ship them.)

### ~~B4 — No privacy manifest~~ — **DONE**

`Sources/VoiceAIKit/PrivacyInfo.xcprivacy` added and declared as the target's only resource. Contents: no tracking, no tracking domains, no collected data types, and one required-reason API — `UserDefaults`, category **CA92.1** (information stored by this app only). Nothing else in the package touches a required-reason API: no file-timestamp reads (the two `resourceValues` calls ask for `isDirectory` / `isRegularFile`), no disk-space query, no boot time. `MemoryProbe`'s `task_vm_info` is not in Apple's list.

Two follow-ons:

- Declaring a resource makes SwiftPM synthesise `Bundle.module` for the target, which spends the old structural guarantee ("no `resources:` block at all"). Replaced by `Tests/VoiceAIKitTests/PackageResourceInvariantTests.swift`, which fails if any file other than the manifest appears under `Sources/VoiceAIKit/`. The `Package.swift` comment was updated to say so.
- The `UserDefaults` entry exists only because of H2. When the locale override moves into `VoiceIntentConfiguration`, delete the whole `NSPrivacyAccessedAPITypes` array rather than editing it.

---

## Contract gaps against the PVA SPEC

These are the items where the Engage adapter, written strictly to `SPEC-voice-understanding-provider.md`, cannot be satisfied by today's public API.

| # | SPEC requirement | Status |
|---|---|---|
| C1 | §6 adapter **MUST** populate `modelBundleVersion` and `modelChecksum` in `ProviderIdentity`; §8 every session **MUST** be attributable | **Not possible.** `VoiceIntentSession` exposes nothing about the pack it bound. The data exists (`ResolvedPack.manifest`, `checksums_root`) but never reaches the facade. `VoiceIntentClient.activePackVersion(for:)` is not an answer — it re-reads `bundle.json` from disk and can disagree with what the live session actually loaded. **Add `session.loadedPack: PackIdentity {version, checksumRoot, language, keyID, channel}`.** |
| C2 | `capabilities` incl. `appOwnedIntentFamilies` and the shared intent catalogue | **Not exposed.** The pack knows its own capability set (`capabilities/*/capability.json`, incl. `messaging.ptt`), nothing public reads it out. The adapter would hardcode a list that silently drifts from the pack it is running — the exact failure class the OTA design was built to eliminate. |
| C3 | `.fallback` → `.unresolved`, **`url` MUST be discarded**; providers **MUST NOT** attempt fallback | Works, but the API shape fights it: `.notUnderstood(fallbackURL: URL, …)` makes a non-optional URL the salient field of the case the host is required to ignore. Make it optional/diagnostic. |
| C4 | adapter **MUST** construct with `audioSource: .injected(...)` | Naming drift only — the kit ships `.appProvided(sampleRate:)` and *enforces* the `speaksPrompts == false` pairing by throwing `internalTTSUnavailableWithAppProvidedAudio`. Update the SPEC; the kit is right. |
| C5 | §"exactly one terminal event per turn" | `.interrupted(cancelledIntent:)` is emitted ahead of the real terminal turn. Needs an explicit carve-out in the SPEC, or the adapter must swallow it. Decide it now, not in review. |
| C6 | `suspendCapture()`/`resumeCapture()` such that no host-TTS audio reaches the recogniser | **Already satisfied**, and well: audio pushed outside `.listening` is dropped, and external-TTS mode parks in `.speaking` until `hostDidFinishSpeaking()`. The 30 s watchdog is a good backstop — but see H7. |

Also note the pva-integration set is dated 31 July, before the August pack/OTA refactor. It should be re-baselined against the current facade before anyone implements against it.

---

## SDK hygiene — fix before a second team links this

**H1 · 758 `public` declarations.** The README says the surface is `init / events / start() / stop() / reset() / classify(text:)`. Reality: `TranscriptionCoordinator`, `SpeechRecognitionService`, `AudioSessionManager`, `AudioCaptureService`, every `Pack*` type and `ResolvedPack`'s whole field list are public. The moment Engage links this, all of it is de-facto API and every rename is a breaking change. Make `Core/`, `NLU/`, `Data/` internal; keep public the facade types, `PackProvider`/`StaticPackProvider`, `PackTrustPolicy`/`PackLoadPolicy`, `VoiceIntentError`, the OTA types, and — instead of exporting `BundleDataLoader` + `PackEngineFactory` so the host can smoke-test — a single `VoiceAIKit.smokeTest(packRoot:language:trust:)`.

**H2 · Hidden global state in the host's `UserDefaults`.** `TranscriptionCoordinator` reads and writes `UserDefaults.standard["stt.userSelectedLocale"]` (lines 121, 130, 144, 441, 471) and `SpeechRecognitionService.performPrewarm` reads it again (line 150), with a hardcoded `"en-IN"` default. An SDK writing an un-namespaced `stt.*` key into the host's standard defaults is bad manners; a *stale persisted value deciding the recogniser locale before `switchLocale` runs* is a correctness bug waiting for a multi-language rollout. Locale should come from configuration, per session, and persist nowhere.

**H3 · `print()` in shipping code.** `print("[Deinit] …")` in `TranscriptionCoordinator`, `ConversationSpeaker`, `NLUContext`, `NLUEngine`, plus `MemoryProbe`'s unconditional prints. Route through `os.Logger`; wrap `MemoryProbe` in `#if DEBUG`.

**H4 · `.allowBluetooth` in `AudioSessionManager.swift:99`** — deprecated on iOS 26 in favour of `.allowBluetoothHFP`, and `.playAndRecord + .duckOthers + .defaultToSpeaker` is precisely the policy Engage must own for a hearing-aid route. Non-issue on the `.appProvided` path Engage will use (D1), but the mic path still ships in the binary. Either compile it out behind a trait or document it as unsupported in host-audio mode.

**H5 · The host must supply ZIP extraction.** `PackExtractor` is host-implemented, and STT satisfies it with ZIPFoundation — so every consumer inherits a third-party dependency to open the SDK's own payload format. The no-networking boundary is correct and well argued; ZIP extraction is not the same kind of decision. Consider an optional `VoiceAIKitZIP` target, or `AppleArchive`.

**H6 · The host-side OTA layer exists only as STT app code.** `NLUOTAManager.swift` (~270 lines), `STTPackExtractor`, `STTNLUEngineProvider`, `OTAStorageLocator`, the BGTask registration — roughly 400 lines a client app must re-derive from reading STT. Extract it into a documented reference adapter, or ship it as an optional module. `docs/BackgroundOTAIntegration.md` + `ExampleOTAManager.swift` are a start; they need to become the supported path.

**H7 · VIK-027: the facade turn state-machine is untested** — and it is exactly the seam Engage depends on (external-TTS handoff, `hostDidFinishSpeaking()`, re-listen vs idle). A host that forgets to call it gets a silent 30 s stall, which in the field reads as "the assistant froze". Needs a mockable engine/coordinator seam and tests before a second host relies on it.

**H9 · The pack test suite has been silently skipping.** *(found 21 Aug, fixed)* `PackTestSupport.packRoot()` walked to `Sources/VoiceIntentSeedPackEN/` and looked for a child with the `pack-` prefix. The seed target now declares `.copy("packs")`, so the packs moved one level down and that directory's children are `SeedPack.swift` and `packs` — neither matches `pack-`. Every one of the ten call sites therefore hit `XCTSkip("No pack-* directory …")`, which XCTest reports as *not failing*. So the loading, entity, classifier, slot-resolver and Python-parity tests — the entire evidence base for "the Swift runtime reproduces the reference" — were green without loading a pack at all. One-line fix applied (`.appendingPathComponent("packs")`); **re-run the suite and treat the first green run as a new baseline**, because nobody knows what it has been hiding since the seed layout changed. A skip that means "this test could not run" should be a failure in CI.

**H8 · README and INTEGRATION.md are stale and will not compile.** README still describes `Resources/` in the package and shows `VoiceIntentConfiguration(language:speaksPrompts:autoStopOnSilence:loadsSemanticRescue:)` with no `packProvider` and no `trust` — both now required with no defaults, deliberately. INTEGRATION.md still documents the pre-OTA Bundle.module world and the STT picker. This is the first thing the Engage team will read.

---

## Pack-contract items that gate GA (not integration)

From `BUG_TRACKER.md`, still open, in the order I would fix them:

- **VIK-008 (High)** — the fitted TF-IDF parameters (`ngram_range`, `min_df`, `sublinear_tf`, `norm`, token pattern) are reproduced in Swift and appear nowhere in the pack. VIK-002 is what this looks like when it drifts: a silent accuracy loss no test catches. It will happen again on the next trainer change.
- **VIK-013 (Med, but paired with the above)** — no golden fixtures in the pack. `Tests/Fixtures/reference_expectations.json` is captured by hand on a developer machine, so nothing proves the pack a *device* receives matches the Python reference. ~20 KB against a 7 MB pack turns every VIK-007/008 drift into a failed assertion at install time. Together these two are the difference between "OTA updates are verified" and "OTA updates are hoped for".
- **VIK-007 remainder (High)** — fuzzy metric, 0.3 edit ratio, 5-char minimum and confidence tiers still hand-mirrored from `entities.py`. The word-list halves are now data-driven; these four are not.
- **VIK-011 (Med)** — empty-feature utterances can clear the 0.70 gate (5/1470 holdout). Surfaced as `isVacuous`, but the pack does not say what should happen, so routing is the caller's guess.
- **VIK-014 (Med)** — `numbers_0_to_31` means "four fifty" cannot resolve as a clock time. Users say that.

Given the device class, I would treat **VIK-008 + VIK-013 as a release gate for the OTA channel**, not as backlog.

---

## What is already right

Worth stating, because it is not the usual state of a first packaging pass:

- Zero-data library, with the acceptance test expressed as the *absence* of a `resources:` block, and the seed pack as a separate product so an app that downloads everything carries 0 MB.
- `PackProvider` — the get-the-bytes / trust-the-bytes split, with the reasoning (auth, background transfer, cellular policy, MDM) written down.
- `PackIntegrity` — signature over `manifest ‖ bundle.json`, `checksums_root` binding the two, verify-before-parse, and no JSON round-trip before hashing. The comment explaining why step 2 is not redundant will save someone a week.
- `VoiceIntentClient.start` — bounded rollback recursion with the seed pack as a guaranteed floor, and a broken OTA pack explicitly unable to throw past `start()`.
- Refuse, don't degrade: no silent fall back to English, ever.
- Engine built *before* the audio hardware is touched, so a pack failure cannot leave a warmed mic stack for a session that can never run.
- `.appProvided` + external TTS + the drop-audio-unless-listening rule — D1/D4 of the ADR, already implemented and enforced by the type system.

---

## Recommended sequencing

**Phase 0 — package, ~3–4 days.** ~~Target split (B1)~~ accepted · ~~privacy manifest (B4)~~ **done** · re-run the pack suite against the H9 fix and set a real baseline · prune the public surface (H1 — plan in [`VoiceAIKit/PUBLIC_API_PLAN.md`](../VoiceAIKit/PUBLIC_API_PLAN.md), Phases 1–2 are the ones that must land before the client app links) · add `PackIdentity` (C1) and a capabilities accessor (C2) · remove the `UserDefaults` locale state (H2) · logging cleanup (H3) · untrack `.build`, drop `.DS_Store` (B3 hygiene) · rewrite README/INTEGRATION (H8).

**Phase 1 — security, in parallel.** Production Ed25519 keypair and `key_id`, compiler signs with it, release policy `refusesDevelopmentPacks: true` enforced structurally, cert pinning on the BFF (B2).

**Phase 2 — Engage adapter.** `VoiceUnderstandingProvider` over `.appProvided` + `speaksPrompts: false`; host runs CMS → GenAI → Wolfram and discards `fallbackURL`; PTT stays app-owned with `resetDialogue()` before dispatch; re-baseline the SPEC against the current facade (C4, C5).

**Phase 3 — GA gate.** Compiler publishes golden fixtures and vectorizer parameters in every pack; adapter asserts them at install (VIK-013, VIK-008).

**Answering the literal question:** a client app must link **both** products — `VoiceAIKit` *and* `VoiceIntentSeedPackEN` — or it ships with no offline floor and cannot classify anything until its first successful OTA download.
