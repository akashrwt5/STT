# VoiceAIKit — public API reduction plan

**Status:** proposed · **Owner:** iOS · **Written:** 21 Aug 2026
**Trigger:** the package is about to be linked by a second host (Engage / PVA). Today's public surface was never designed; it is whatever `public` was needed to make the package compile out of the app's sources.

---

## 1. The problem, in numbers

| | Count |
|---|---|
| Declarations starting with `public` / `open` in `Sources/VoiceAIKit` | **745** |
| Distinct package symbols the only real host (STT) actually names | **18** |
| Symbols the README claims are the API | **6** |

The README says the surface is `init`, `events`, `start()`, `stop()`, `reset()`, `classify(text:)`. The compiler says otherwise: `TranscriptionCoordinator` (34 public declarations), `SpeechRecognitionService` (12), `AudioSessionManager` (12), `PackSections` (125), `PackLexicon` (57), `NLUBundle` (57), `ResolvedPack` (45), `DialogSchema` (36) and the rest are all reachable from a host app.

This matters on exactly one date: **the day Engage links the package.** After that, every one of those 745 declarations is a name someone can write in a client app, and every rename is a breaking change to be negotiated with another team. Before that date it costs a day of mechanical work.

Worst case is not a rename. It is a client engineer who hits a gap in the facade — no pack version, no capability list — reaches past it into `ResolvedPack.manifest` because it happens to be public, and ships that. Now the internal data layer is load-bearing in someone else's release train, and the facade gap that caused it is never reported.

**Target: ~110 public declarations across ~24 types**, and — more useful as a rule of thumb — *a host must be able to integrate without importing anything from `Core/`, `NLU/` or `Data/`.*

---

## 2. The rule

> **Public means: a name the host is required to write.**

Three tiers qualify, and nothing else does.

- **Tier 1 — the session.** What you need to run a turn.
- **Tier 2 — the OTA host contracts.** Protocols the host *implements* (`PackProvider`, `PackExtractor`, `NLUEngineProvider`) and the types it *drives* (`VoiceIntentClient`, the installer, storage, validator, trust policy).
- **Tier 3 — three new entry points** that exist specifically so Tier 1 and 2 stop leaking internals. Without these, `BundleDataLoader`, `PackEngineFactory`, `PackIntegrity`, `ResolvedPack` and `NLUBundle` cannot go internal, because the host genuinely needs what they do today.

Everything under `Core/`, `NLU/` and `Data/` fails the rule.

---

## 3. Tier 3 — the three additions that unblock the demotion

These come first. They are the only part of this plan that is design rather than mechanics, and they each close a gap the readiness review already recorded.

### 3.1 `PackIdentity` — who is actually loaded ✅ SHIPPED

As built, in `Facade/PackIdentity.swift`:

```swift
public struct PackIdentity: Sendable, Equatable {
    public let bundleID: String        // "pack-en-v1.0.36"
    public let version: String?        // "1.0.35" — read, never derived from bundleID
    public let checksumRoot: String    // bundle.json checksums_root — the signed root
    public let keyID: String           // signature_info.key_id — verification enforces it
    public let channel: String         // "dev" | "production", verbatim
    public let compilerVersion: String // "nlu-compiler 1.0.0-content"
    public let createdAt: String       // ISO-8601
    public let languages: [String]     // what the PACK declares, sorted
}
```

Three differences from the sketch below, each forced by what `bundle.json` actually holds:

- **`version` is optional, and separate from `bundleID`.** `NLUBundle` — the model the
  session path decodes — did not read the field at all; it was added for this (VIK-034).
  Optional so packs already on devices keep loading. And it is NOT parsed out of the
  bundle id: the two are independent fields that genuinely differ in the current seed
  pack, so deriving one would silently disagree with what the OTA path reports.
- **No `language`.** The sketch conflated the language a pack CARRIES with the one a
  session BOUND. The session already knows the second from its own configuration, so
  this type reports only the first and means the same thing wherever it came from.
- **`keyID` is non-optional.** `PackIntegrity` throws when `signature_info.key_id` is
  absent, so an identity cannot exist without one.

*Original sketch, kept for its reasoning:*

```swift
public struct PackIdentity: Sendable, Equatable {
    public let bundleID: String        // "pack-en-v1.0.36-ios"
    public let version: String         // "1.0.36"
    public let language: String        // "en"
    public let checksumRoot: String    // bundle.json checksums_root — the signed root
    public let keyID: String?          // nil when trust skipped verification
    public let channel: String         // "development" | "production"
}
```

Exposed two ways:

```swift
extension VoiceIntentSession {
    /// The pack this session bound, or nil before `start()` / first `classify`.
    public private(set) var loadedPack: PackIdentity? { get }
}
```

Why it matters beyond tidiness: `SPEC-voice-understanding-provider.md` §6 requires the adapter to populate `modelBundleVersion` and `modelChecksum` in `ProviderIdentity`, and §8 requires every session to be attributable. Today that is impossible without reading `ResolvedPack` — which is precisely the reach-past-the-facade this plan is trying to prevent. `VoiceIntentClient.activePackVersion(for:)` is not a substitute: it re-reads `bundle.json` from disk and can disagree with what the live session actually loaded.

### 3.2 `VoiceIntentPack.verify(at:language:trust:policy:) -> PackIdentity` ✅ SHIPPED

Shipped as a static on a new `VoiceIntentPack` enum, not on a type named after the
module — that would be ambiguous with the module itself at every call site.

It runs the **same** checks a real load runs rather than a cheaper subset:
`BundleDataLoader`'s steps 1–5 (trust chain → decode from the verified bytes → runtime
compatibility → dev-pack refusal + report-card gates → language availability) were
extracted into `verifiedManifest(packAt:language:trust:policy:)`, and both paths call it.
A pre-check that only walked the sha256 table would wave through an incompatible,
dev-signed or gate-failing pack while reading, at the call site, as though it had caught
everything.


Replaces the host's direct call to `PackIntegrity.verify` (`PackProviderForApp.packURL(for:)`, `PackageVoiceView.swift:63`). The host's question is *"is this directory safe to serve?"* — it does not need `PackIntegrity.Verified`, the digest table, or the verified `bundle.json` bytes. Return the identity instead; it is the answer to the next question anyway.

Lets `PackIntegrity` (17), `BundleDataLoader` (3) go internal.

### 3.3 `VoiceIntentPack.smokeTest(packRoot:language:trust:probe:) -> PackIdentity` ✅ SHIPPED


Replaces `BundleDataLoader.load(...)` + `PackEngineFactory.makeEngine(...)` + `engine.handle("hello")` in `STTNLUEngineProvider.smokeTest` (`STTApp.swift:49`). That sequence is the SDK's own dress rehearsal, copied into every host — and a host that copies it slightly wrong (different `trust`, different variant) makes the OTA idle-gate meaningless while looking correct.

Lets `PackEngineFactory` (9) and the whole `Data/` tree go internal.

> Do **not** also add a `capabilities` accessor in this pass. It is needed (SPEC §C2), but it is a design question — which shape does the adapter want, pack capability IDs or the shared intent catalogue? — and it should not block a mechanical demotion.

---

## 4. The keep-list

Everything below stays `public`. Everything not below becomes `internal`.

### Tier 1 — session (`Facade/`, plus two)

| Symbol | File | Note |
|---|---|---|
| `VoiceIntentSession` | `Facade/VoiceIntentSession.swift` | `init`, `events`, `state`, `start`, `stop`, `reset`, `provideAudio`, `hostDidFinishSpeaking`, `classify(text:)`, **new** `loadedPack` |
| `VoiceIntentConfiguration` | `Facade/VoiceIntentTypes.swift` | |
| `VoiceLanguage`, `AudioSource` | ″ | |
| `VoiceSessionState`, `VoiceIntentTurn`, `VoiceIntentStages`, `VoiceIntentEvent` | ″ | |
| `VoiceIntentConfigurationError` | ″ | |
| `PackProvider`, `StaticPackProvider` | `Facade/PackProvider.swift` | host implements the first |
| `VoiceIntentError` | `Data/VoiceIntentError.swift` | thrown at the host; the one `Data/` export |
| `SilenceDetectionConfiguration` | `Core/Models/` | reachable from `VoiceIntentConfiguration`; the one `Core/` export — **trim to the presets + memberwise init** (20 → ~10) |

### Tier 2 — OTA host contracts

| Symbol | File | Note |
|---|---|---|
| `VoiceIntentClient`, `VoiceIntentClientError` | `VoiceIntentClient.swift` | |
| `NLUPackInstaller` | `OTA/Installer/` | ✅ `preparePack` returns `PackIdentity` (VIK-034) |
| `PackState` | `OTA/Models/` | |
| `PackStorageControlling`, `PackStorageController` | `OTA/Storage/` | |
| `PackValidating`, `PackValidator` | `OTA/Validation/` | |
| `PackExtractor` | `OTA/Validation/` | host implements |
| `NLUEngineProvider` | `OTA/` | host implements |
| `PackTrustPolicy`, `PackLoadPolicy` | `Data/PackIntegrity.swift` | move to `Facade/` or `OTA/`; they are host policy, not data-layer detail |
| ~~**trim** `NLUPackManifest`~~ | ~~`OTA/Models/`~~ | ✅ **DELETED** in VIK-034, along with `EngineCompat`, `SignatureInfo`, `LanguageStatus`, `CapabilityStatus`, `ModelArtifact`, and the two resolution types (now internal). 44 public declarations across 8 types, gone. `PackIdentity` took its place on `PackValidating` and `preparePack` |

### Tier 3 — new

`PackIdentity`, `VoiceAIKit.verifyPack(...)`, `VoiceAIKit.smokeTest(...)`.

### Demote — everything else

| Directory | Public declarations today | After |
|---|---|---|
| `Data/` (13 files: `PackSections`, `PackLexicon`, `NLUBundle`, `ResolvedPack`, `DialogSchema`, `PackIntegrity`, `PackEntityExtractor`, `PackSlotResolver`, `PackIntentClassifier`, `PackTFIDFVectorizer`, `PackDateTimeParser`, `PackEngineFactory`, `BundleDataLoader`) | 409 | 0 (`VoiceIntentError` + the two policies relocated) |
| `Core/` (14 files: coordinator, recognition, audio, models, protocols) | 122 | 0 (`SilenceDetectionConfiguration` relocated) |
| `NLU/` (`NLUEngine`, `NLUContext`, `ConversationSpeaker`, `ConfirmationGate`, `NLUResponse`, `NLUProtocols`, `SlotFormatting`, `MemoryProbe`) | 53 | 0 |

`MemoryProbe` goes internal **and** behind `#if DEBUG` — it prints unconditionally today.

---

## 5. Mechanics

**Tests keep working.** Every test file already uses `@testable import VoiceAIKit`, which sees internal symbols. No test should need editing for the demotion itself — if one does, that is a signal the type belonged to the facade after all. Note it rather than making it public again.

**Temporary escape hatch.** For anything the STT app still touches mid-migration:

```swift
@_spi(VoiceAIKitInternal) public func …          // in the package
@_spi(VoiceAIKitInternal) import VoiceAIKit  // in the host
```

SPI keeps a symbol out of the public interface while remaining callable, and the import line makes every reach-in greppable. **Every `@_spi` added in Phase 2 must be gone by Phase 5** — otherwise this plan has produced a second, less visible public API.

**The one non-mechanical gotcha: public conformances to now-internal protocols.** `VoiceIntentSession` conforms to `TranscriptionDelegate`, and its six delegate methods are declared `public` in that extension. When `TranscriptionDelegate` goes internal the conformance must go internal too — drop `public` from all six (`didReceivePartialResult`, `didReceiveFinalResult`, `didEncounterError`, `didChangeState`, `didReachEndOfSpeech`, `didUpdateAudioLevel`). A public type may conform to an internal protocol; it may not do so with public members. The same applies to `AppAudioInputProvider: AudioInputProvider` (both go internal, so no issue) and any `Sendable`/`Equatable` conformance on a demoted type.

**Do not use `open` anywhere.** Nothing in this package is designed for cross-module subclassing, and `open` on a class the host can override turns every internal call into a contract.

**No ABI risk.** The package has library evolution off, is consumed by source as a local package, and has exactly one consumer today. Demotion is source-breaking for the STT app and the test target — both in this repo, both fixed in the same commit. This is the cheapest moment this will ever be; it gets roughly twice as expensive the day Engage links it and permanently more expensive after Engage ships.

---

## 6. Phases

| Phase | Work | Acceptance | Est. |
|---|---|---|---|
| **1** ✅ | **DONE** — `PackIdentity`, `VoiceIntentPack.verify`, `VoiceIntentPack.smokeTest`, `session.loadedPack` are in (see §3 for what actually shipped). Remaining: `preparePack` returns `PackIdentity`. Migrate the three STT call sites (`STTApp.swift:49`, `STTApp.swift:139`, `PackageVoiceView.swift:63`). | STT app builds; no host file imports anything from `Data/` | ½ day |
| **2** ✅ | **DONE** — 69 top-level declarations across 33 files in `Core/`, `NLU/`, `Data/` flipped to `internal`; 4 kept public (`SilenceDetectionConfiguration`, `PackTrustPolicy`, `PackLoadPolicy`, `VoiceIntentError`). The predicted conformance fallout was exactly the six `TranscriptionDelegate` methods on `VoiceIntentSession`. No `@_spi` was needed. Remaining: the 3 STT call sites. | Package + tests build | 1 day |
| **3** ✅ | **DONE** — 504 member-level `public`s inside now-internal types stripped; the four `print("[Deinit] …")` calls moved to `os.Logger` at `.debug`. `MemoryProbe` needed nothing — it is already `#if DEBUG`. The `NLUPackManifest` trim, deferred here, landed with **VIK-034**: the type and its seven companions are deleted rather than trimmed, and `PackIdentity` is what the OTA surface vends. See §6.1. | 686 → 178 public declarations; 38 public types, then −8 with VIK-034 | ½ day |
| **4** | CI guard (§7). | A PR that adds a public symbol fails until the snapshot is updated deliberately | ½ day |
| **5** | Remove every `@_spi` from Phase 2. Rewrite `README.md` and `INTEGRATION.md` against the real surface — both currently show a `VoiceIntentConfiguration` init with no `packProvider` and no `trust`, which will not compile. | Zero `@_spi` in the repo; README compiles as written | ½ day |

**Total ≈ 3 days**, and Phases 1–2 are the ones that must land before Engage links the package. Phases 3–5 can follow, but not by much: Phase 5 is what a client engineer reads first.

---

## 7. Keeping it small

A one-time cleanup regrows. The guard is a checked-in snapshot of the public surface, diffed in CI (`.github/workflows/` already runs on macOS):

```bash
swift package dump-symbol-graph --minimum-access-level public
jq -r '.symbols[] | select(.accessLevel == "public") | (.pathComponents | join("."))' \
   .build/*/symbolgraph/VoiceAIKit.symbols.json | sort -u > docs/public-api.txt
git diff --exit-code docs/public-api.txt
```

A PR that widens the surface fails, and the fix is to commit the new snapshot — which puts the decision in the diff, where a reviewer sees it. `swift package diagnose-api-breaking-changes <baseline>` is the complementary check for the other direction once the package carries version tags.

---

## 8. What this does not fix

Out of scope here, tracked in `docs/VIK_CLIENT_APP_READINESS.md`:

- **H2** — `UserDefaults.standard["stt.userSelectedLocale"]`. Access control does not help: a private write to the host's shared defaults is still a write to the host's shared defaults. The locale must move into `VoiceIntentConfiguration` and persist nowhere. Do it during Phase 2 while `Core/` is already open on the bench.
- **C2** — the capabilities accessor. Needs an adapter-side design decision first.
- **B2** — the production trust policy. Unrelated to the surface, and more urgent than all of it.

---

## 6.1 Why `NLUPackManifest` was still public — RESOLVED

Phase 3 planned to trim it: 44 public declarations across 8 top-level types
(`NLUPackManifest`, `EngineCompat`, `SignatureInfo`, `LanguageStatus`, `ModelArtifact`,
`CapabilityStatus`, `ModelResolution`, `ModelResolutionError`) for a type whose only
host-side read is `.version`. That is the single largest remaining block of surface.

It is deferred, deliberately. Making it internal requires changing what
`PackValidating.extractAndValidate` returns, because a public protocol cannot vend an
internal type — and `PackValidating` has to stay public, since `VoiceIntentClient.init`
takes one. So the change is not "mark it internal"; it is a signature change on the
OTA install path, in the code that decides which pack becomes `Current` on a user's
device.

Three reasons to wait:

1. ~~**`PackIdentity.version` is optional and `NLUPackManifest.version` is not.**~~
   **RESOLVED** — `nlu_compiler` `bd3c5bf` emits `version` inside the signed bytes, from the
   same variable as `bundle_id`. Both models now require it, so "what does the installer do
   when the version is nil?" no longer needs an answer: it cannot be nil. Reasons 2 and 3
   below still stand.
1. *(superseded)* **`PackIdentity.version` is optional and `NLUPackManifest.version` is not.** The
   installer names staging and active directories from the version, so swapping the
   return type means deciding what an OTA pack with no version does. That is a real
   behavioural decision, not a mechanical one.
2. **VIK-034 would redo the work.** There are two Decodable models of `bundle.json`
   (`NLUBundle`, `NLUPackManifest`) reading different subsets of it. Unifying them is
   the actual fix and it lands on exactly these files. Trimming one of the two first
   means doing this twice.
3. **Risk / value.** The win is a public-surface number. The cost is untested churn in
   the install path. Every other item in this plan was mechanical or compiler-checked;
   this one is neither.

**Do it as part of VIK-034**, once the compiler team confirms whether `version` is
guaranteed. Then one manifest type, decoded once from verified bytes, `PackIdentity`
vended to hosts, and the eight types collapse together instead of one at a time.

---

### ✅ Done — that is exactly what happened

VIK-034 is fixed and this section is closed. `NLUPackManifest` is deleted, not trimmed;
`NLUBundle` is the one model of `bundle.json`; `PackValidating.extractAndValidate` and
`NLUPackInstaller.preparePack` return `PackIdentity`. All eight types went together.

Reason 3 — "the cost is untested churn in the install path" — was answered rather than
accepted. The install path now has assertions it did not have before: the validator's
first positive-path test, the dev-pack refusal against the real seed pack, and a token-guard
test that distinguishes a rebuilt staging directory from a relabelled one. Verified on
iOS Simulator 26 and against a live OTA install in the STT app.

The change also paid for itself outside the surface number: because `NLUPackManifest` had
no `channel`, the OTA installer could not enforce `refusesDevelopmentPacks` and a dev pack
was refused only after activation. It is refused at validation now. See `BUG_TRACKER.md`
VIK-034.
