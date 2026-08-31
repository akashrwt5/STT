# Pending work — split by repo

**Purpose of this document.** `VoiceAIKit` is about to be linked into a second
client app (Engage) **to check compatibility, not to ship**. This lists
everything still open across the two repos, says which side owns it, and labels
what that decision actually gates.

Sources: `VoiceAIKit/BUG_TRACKER.md` (10 open), `IntentClassifier/docs/BUG_TRACKER.md`
(13 open), and the non-tracker items in `docs/VIK_CLIENT_APP_READINESS.md`.

State at the time of writing: package builds clean, the full test suite runs
green on iOS Simulator 26, public surface pruned (107 → 38 types), README and
INTEGRATION.md rewritten, pack `pack-en-v1.0.38-ios`.

---

## Label legend

| Label | Meaning |
|---|---|
| **`COMPAT`** | Do it before, or during, the Engage compatibility integration. Skipping it means the spike either cannot run or produces a misleading result. |
| **`GA`** | Not needed for the spike. Must be closed before anything reaches a user. |
| **`BACKLOG`** | Real, worth fixing, gates nothing. |

Severity in the tables is the tracker's own severity, unchanged. The label is a
separate axis — a **High** severity item can still be `GA`, and a **Low** one can
be `COMPAT` if it blocks the spike mechanically.

---

## 1. iOS — `STT/VoiceAIKit`

### 1a. Owned entirely by iOS (no Python dependency)

| ID | Sev | Item | Label | Why that label |
|---|---|---|---|---|
| **VIK-027** | Med | Facade turn state-machine untested — external-TTS handoff (`hostDidFinishSpeaking()`), re-listen vs idle, 30 s watchdog. Needs a mockable coordinator/engine seam. | **`COMPAT`** | This is *exactly* the seam Engage runs on (`.appProvided` audio + `speaksPrompts: false`). It has no test coverage at all. A host that mis-sequences the handoff gets a silent 30-second stall that reads as "the assistant froze" — and the spike would report that as a kit bug with nothing to bisect against. |
| **H6** | — | Host-side OTA layer exists only as STT app code (`NLUOTAManager` ~270 lines, `STTPackExtractor`, `STTNLUEngineProvider`, `OTAStorageLocator`, BGTask registration ≈ 400 lines). | **`COMPAT` if OTA is in scope, else `GA`** | Engage cannot exercise OTA without re-deriving 400 lines by reading STT. If the spike is "link it, feed audio, get intents" this can wait; if it is "does OTA work in their app", extract the reference adapter first. |
| **H5** | — | Host must supply ZIP extraction (`PackExtractor` is host-implemented; STT uses ZIPFoundation). | **`COMPAT` if OTA is in scope, else `GA`** | Same gate as H6. The no-networking boundary is right; making every consumer inherit a third-party unzip to open our own payload is not. Options: an optional `VoiceAIKitZIP` target, or `AppleArchive`. |
| **C5** | — | `.interrupted(cancelledIntent:)` is emitted ahead of the real terminal turn, against the SPEC's "exactly one terminal event per turn". | **`COMPAT`** | This is a *decision*, not code — either the SPEC gets a carve-out or the adapter swallows the event. Cheap now, expensive after Engage has written their adapter around the current behaviour. |
| **C2** | — | No public accessor for the pack's capability set (`capabilities/*/capability.json`, incl. `messaging.ptt`) — `appOwnedIntentFamilies` cannot be populated. | **`GA`** | For a compatibility check the adapter can hardcode the list. For production a hardcoded list drifts silently from the pack, which is the failure class OTA exists to remove. |
| **VIK-030** | Med | `runtime/routing.json` is decoded and never read — the pack's `ladder` and `assist_cloud` switch do nothing. | **`GA`** | Every pack ships it and no code path consults it, so the pack cannot change the behaviour it appears to control. All three routes (out of scope, below gate, 3 failed slot attempts) currently collapse into one `.fallback(intent:)`. A host wanting the ladder has to rebuild it from confidence alone. |
| ~~**VIK-034**~~ | Med | ~~Two independent `Decodable` models of `bundle.json`.~~ | **✅ FIXED** | One model (`NLUBundle`), `PackIdentity` on the OTA surface, `NLUPackManifest` + 7 companion types deleted, and the `refusesDevelopmentPacks` check moved from session load to validation. Also closed `PUBLIC_API_PLAN` §6.1. Verified on Simulator 26 and against a live OTA install. |
| **H4** | — | `AudioSessionManager.swift:99` uses `.allowBluetooth`, deprecated on iOS 26 in favour of `.allowBluetoothHFP`. | **`BACKLOG`** | Engage runs `.appProvided` audio, so the mic path is not on their route — but the code still ships in their binary and will raise a deprecation warning in their build. Either compile it out behind a trait or document host-audio mode as the only supported path. |
| **VIK-012** | Low | `DateTimeGrammar` lookup tables are computed properties — rebuilt on every access, i.e. per utterance. | **`BACKLOG`** | Correctness is fine; it is wasted work per turn. Build once at `PackDateTimeParser.init`. |
| **H3** | — | `print()` in shipping code. | **Closed — verified** | Only `MemoryProbe` still prints, and the whole file is inside `#if DEBUG` (line 11). Nothing else in `Sources/` prints. |

### 1a-bis. Found outside both trackers — STT app configuration

| Item | Sev | Label | Detail |
|---|---|---|---|
| **Background OTA refresh has never run** | Med | **`GA`** | `STTApp.swift:182` registers `.backgroundTask(.appRefresh("com.starkey.stt.nlu.refresh"))` and line 192 submits a matching `BGAppRefreshTaskRequest`, but neither `BGTaskSchedulerPermittedIdentifiers` nor `UIBackgroundModes` exists anywhere in the project — `GENERATE_INFOPLIST_FILE = YES`, no physical `Info.plist`, and the `INFOPLIST_KEY_*` settings cover only mic, speech and orientation. iOS therefore rejects the registration and `submit()` fails with `Unrecognized Identifier`. Foreground `checkForUpdates` works, which is why nobody noticed: the background path is silently dead, not broken. Fix is two Info keys in the STT target — app-side, not the package. |

### 1b. iOS consumes, Python must emit first

These are listed again in §2 under the Python owner. They are here so the iOS
side of the work is visible.

| ID | Sev | iOS-side work, once the pack carries it | Label |
|---|---|---|---|
| VIK-010 | Med | Delete the `head.json` entry from `PackLoadPolicy.toleratedMissingArtifacts`. | `GA` |
| VIK-007 | **High** | Read `fuzzy: {algorithm, max_distance_ratio, min_length}` from the pack instead of hand-mirrored Python constants. | `GA` |
| VIK-008 | **High** | Read the fitted vectorizer configuration from the pack instead of reproducing `ngram_range`/`min_df`/`sublinear_tf`/`norm`/token pattern in Swift. | `GA` |
| VIK-013 | Med | Assert the pack's published golden fixtures at install, and retire the hand-captured `Tests/Fixtures/reference_expectations.json`. | `GA` |
| VIK-014 | Med | Flip `PackDateTimeParityTests`' known-gap assertion once a `clock_minutes` table exists. | `GA` |
| VIK-026 | Med | Replace `weekdayStripMinimumLength = 4` with the pack's `strippable` list. | `GA` |
| VIK-011 | Med | Route vacuous predictions per the pack's stated contract instead of the caller's guess. | `GA` |

---

## 2. Python — `IntentClassifier`

### 2a. Pack contents — what the device actually receives

| ID | Sev | Item | Label | Why that label |
|---|---|---|---|---|
| **BUG-014** | **High** | No MiniLM embedder or vocab in the pack, despite `bundle.json` declaring `"embedder_id":"minilm-l6-v2"`. Verified on `pack-en-v1.0.38-ios`: `models/semantic_head/shared/SemanticHead.mlpackage` ships, the embedder that feeds it does not. | **`COMPAT` if Engage enables `loadsSemanticRescue`, else `GA`** | Stage 3 of the classifier cannot run from the pack. If the spike turns semantic rescue on, it will silently do nothing and the compatibility result will be wrong in our favour. Decide the flag before the spike starts. |
| **BUG-013** | **High** | `head.json` declared in `bundle.json`, absent from every pack. Confirmed still absent in v1.0.38. | **`GA`** | Tolerated on iOS by an explicit entry in `PackLoadPolicy.toleratedMissingArtifacts`. Paired with VIK-010 — the tolerance is a workaround for this defect and comes out when this is fixed. |
| **BUG-012** | **High** | Two eval fixtures still on the dead `Cmd.*` taxonomy — they score 0% and nothing says so. | **`GA`** | Not device-facing, but it means the eval numbers we quote are measured against a partly-dead harness. |
| **BUG-019** | Med | ~56% of pack bytes are never read by any mobile client. Pack is 7.1 MB, of which `models/` is 6.9 MB, and it carries both `.mlpackage` and `.mlmodelc` of both the standard and `_full` classifier. | **`GA`** | It is app size on a hearing-aid companion, and it is 6.9 MB per OTA download. Not wrong, just paid for repeatedly. |
| **BUG-015** | Med | Server-side temperature shipped device-side with its warning stripped. | **`GA`** | A calibration constant applies to the model it was fitted on; shipping it without the caveat invites its use on the device variant. |
| **BUG-016** | Med | `temperature_int8` not shipped although `model_int8.tflite` is. | **`GA`** | Same class as BUG-015 — a quantised model with no matching calibration. |
| **BUG-021** | Med | Startup integrity check verifies files the engine does not load. | **`GA`** | Verification cost paid on artifacts nothing reads, while BUG-013/014 show the reverse also happens. |
| **BUG-020** | Low | `labels.pkl` — a Python pickle — shipped to mobile clients. Confirmed present at `models/intent/en/labels.pkl` in v1.0.38. | **`GA`** | `labels.json` sits beside it and is what iOS reads. A pickle is an executable format; it should not be in a payload we sign and hand to phones. |
| **BUG-017** | Low | Entity id separator differs between the v3 surface and the root shim. | **`BACKLOG`** | Absorbed on the iOS side already; it is a format inconsistency, not a failure. |
| **BUG-018** | Low | `.DS_Store` shipped inside the pack. Confirmed: `Sources/VoiceAISeedPackEN/packs/.DS_Store` is inside the `.copy("packs")` resource, so it lands in the app bundle. | **`BACKLOG`** | Harmless — it sits outside the signed `pack-en-*` directory, so it does not affect the manifest. Still, it ships. |

### 2b. Contract emissions iOS is waiting on

| ID | Sev | What the compiler must emit | Label |
|---|---|---|---|
| **BUG-014 / VIK-008** | **High** | The fitted TF-IDF vectorizer configuration, machine-readably, beside the weights. Today `calibration.json` has it as a prose string and the pack strips even that. | **`GA` — release gate for the OTA channel** |
| **VIK-013** | Med | ~200 golden utterances with expected label and confidence to 4dp, emitted by the model's own build. ~20 KB against a 7.1 MB pack. | **`GA` — release gate for the OTA channel** |
| **VIK-007** | **High** | The remaining `fuzzy` constants: metric (Levenshtein), 0.3 edit ratio, 5-char minimum, confidence tiers. The two word-list halves already ship in `lexicons/en.json`. | **`GA`** |
| **VIK-014** | Med | A `clock_minutes` table, or extend `numbers_0_to_31` to 0–59 and rename it. Today "four fifty" cannot resolve as a clock time on device; the reference gets it right from a hardcoded table. | **`GA`** |
| **VIK-026** | Med | Mark which weekday synonyms are safe to strip from free text (`"Monday": {"strippable": ["monday"]}`). Without it iOS guesses by string length. | **`GA`** |
| **VIK-011** | Med | State the empty-feature contract — what should happen when no token matches the vocabulary (5/1470 holdout rows clear the 0.70 gate on intercepts alone). | **`GA`** |
| **VIK-031 follow-on** | — | Drop `genai_base_url` from the weights blob (iOS no longer reads it), and replace the `Default Fallback Intent.done` response, which currently reads **"Done."** — what a hearing aid would say aloud to a user it did not understand. | **`GA`** |

### 2c. Build and tooling (Python repo internal)

| ID | Sev | Item | Label |
|---|---|---|---|
| BUG-009 | **High** | 4 `make` targets point at a deleted tree; `make check` is broken. | **`GA`** — it is the gate everything else is supposed to pass through. |
| BUG-010 | Med | `make typecheck` and CI MyPy check different trees. | `BACKLOG` |
| BUG-011 | Low | `make format-check` stricter than CI. | `BACKLOG` |

---

## 3. Needs both repos

| Item | iOS side | Python side | Label |
|---|---|---|---|
| **B2 — production trust policy** (deferred by explicit decision: "security keys wala production ke around karenge") | Ship a real policy with `refusesDevelopmentPacks: true` — STT and `PackageVoiceView` both hardcode `.unverifiedForTesting`. The enforcement points are now in place at both layers (VIK-034 added the validator-side refusal); what is missing is a policy that turns them on. Pin the BFF certificate. | Generate the production Ed25519 keypair, sign releases with it, publish `key_id`. | **`GA` — hard blocker for production, deliberately not now.** Until this lands, an attacker-authored pack is a trusted pack. |

---

## 4. What this means for the Engage compatibility spike

**Nothing in either tracker blocks linking the package and running intents.**
The package builds, the suite is green against a real pack, and the public API
is the one documented in INTEGRATION.md. Engage must link **both** products —
`VoiceAIKit` *and* `VoiceAISeedPackEN` — or it ships with no offline floor and
cannot classify anything until its first successful OTA download.

Four decisions to take **before** the spike starts, not during:

1. **Is OTA in scope?** If yes, H5 + H6 first — otherwise Engage re-derives
   ~400 lines from STT and any problem they hit is unattributable.
2. **Is `loadsSemanticRescue` on?** If yes, BUG-014 first — otherwise stage 3
   silently no-ops and the compatibility result flatters us.
3. **C5** — SPEC carve-out for `.interrupted`, or adapter swallows it. Decide
   before their adapter is written around today's behaviour.
4. **VIK-027** — the external-TTS handoff is the seam Engage depends on and it
   is untested. Either land the mockable seam, or go in knowing that any
   "it froze" report has no test to bisect against.

Everything else on both lists is `GA` or `BACKLOG` and does not need to move for
a compatibility check.
