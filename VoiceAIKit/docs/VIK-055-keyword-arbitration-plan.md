# VIK-055 — Keyword arbitration parity (iOS)

**Status:** proposed
**Owner:** VoiceAIKit / NLU
**Pack under test:** `pack-en-v1.0.54` (identical content on iOS and Android)
**Reference:** `IntentClassifier/packages/runtime/nlu_engine/classifier.py::IntentClassifier.classify`
**Ticket already named in-tree:** `ReferenceParityTests.testEngineDecisionsMatchTheReference` (VIK-055)

---

## 1. Summary

iOS treats a keyword rule match as a **bypass**: `NLUEngine.handleNewIntent` Stage 0
(`NLUEngine.swift:543`) returns the rule's intent before the classifier ever runs.
Android and the Python reference treat it as a **vote**: the model runs on every turn,
and rule-vs-model agreement decides both the label and the bar it must clear.

This plan moves keyword matching and arbitration into `PackClassifierAdapter`, deletes
Stage 0 from `NLUEngine`, and wires `policies.thresholds.agreement` — which iOS decodes
today (`PackSections.swift:168`) and reads nowhere.

Scope is deliberately **one behavioural change**. Five further verified divergences are
recorded in §12 and are explicitly *not* in this change.

---

## 2. Evidence — the failing case

Utterance: `"who is the prime minister of create reminder"`

Keyword rule (byte-identical in both packs, no guards):

```
\b(set|create|add|make)\b.{0,20}\breminder\b   ->  reminders.add
```

Model verdict, computed from the pack's own full-vocab head (5896 features):

| | backend | temperature | top-1 | `reminders.add` |
|---|---|---|---|---|
| Android | `model.onnx` | `temperature` = 0.671457 | `Default Fallback Intent` **0.640** | #2 @ 0.237 |
| iOS | `IntentClassifier_full.mlmodelc` | `temperature_coreml_full` = 0.54399 | `Default Fallback Intent` **0.729** | #2 @ 0.213 |

OOV ratio for this utterance: **0.25** — exactly `policies.thresholds.oov_reject`.

**Android decision trace** (`OfflineNluServiceImpl.classifyOnPack`):

```
keyword = reminders.add
model   = Default Fallback Intent        -> disagree
corroborated = false
confidence   = contestedConfidence 0.60
fireBar      = thresholds.confidence 0.70
0.60 < 0.70  -> Default Fallback Intent          [correct]
```

**iOS decision trace** (`NLUEngine.handleNewIntent`):

```
Stage 0 matchKeywordTrigger -> reminders.add
helpRedirect                -> nil   ("who is" is not in the help_marker pattern)
                            -> extractAllSlots + fillOpenTopics + advanceSlots + RETURN
```

The classifier never runs. Three guards that would each have caught this turn all sit
*after* Stage 0:

- the fire threshold, `conf < schema.confidenceThreshold` (`NLUEngine.swift:668`)
- the OOV guard, `oov_reject 0.25 / oov_bypass 0.97` (`NLUEngine.swift:659-666`)
- the vacuous-prediction check in `PackClassifierAdapter.classifyAsync`

The pack data is not implicated. A full tree hash of both packs differs only in
platform model artifacts (`model.onnx` vs `.mlmodelc` + weights JSON), the
per-backend temperature keys in `calibration.json`, `bundle.json`, and the integrity
manifest. `keywords/en.json`, `workflows.json`, `lexicons/en.json` and
`runtime/policies.json` are byte-identical.

---

## 3. Root cause

`classifier.py::classify` documents this exact defect as already fixed on the Python
side:

> "Previously the keyword stage short-circuited the model and returned a hardcoded
> constant, which put two incompatible scales in one field. […] Corroborated (rule and
> model agree) measures 99.1% correct; contested (they disagree) measures ~45% on the
> honest holdout — a coin flip, and exactly the condition a confirmation exists to catch."

Android ports the fixed version. **iOS still runs the pre-fix short-circuit.**

`NLUEngine.swift:528-541` acknowledges the divergence in a comment and works *around*
it (a Stage 0 "help guard declined" special case) rather than closing it.

---

## 4. Why the fix goes in `PackClassifierAdapter`, not `NLUEngine`

Two seams were available. The adapter wins on both correctness and blast radius.

| | Arbitration in `PackClassifierAdapter` | Arbitration in `NLUEngine` |
|---|---|---|
| Matches reference | Yes — `classifier.py` owns arbitration; `engine.py` only reads `last_arbitration` | No — invents a third shape |
| Test stubs | Stubs **are** the classifier, so they bypass arbitration and keep today's behaviour | Every stub now runs arbitration; keyword-routed test utterances become contested and fall back |
| Files touched | 4 | 4 + at least 4 test files rewritten |
| Guard fidelity | Reads `PackKeywords.Rule` directly — all guards, not just `guards.first` | Would keep the lossy `KeywordTrigger` projection |

The second row is the decisive one. `ConfirmationAndSlotFlowTests`,
`HelpMarkerGuardTests`, `OpenSlotNameDerivationTests` and `ReferenceParityTests` all
inject fixed-label stub actors. Putting arbitration in the engine would make every one
of those stubs a permanent disagreement with the pack's keyword rules.

---

## 5. Target design

Per-turn order after the change, mirroring `engine.py::_classify_new` lines 1195-1293
and `OfflineNluServiceImpl.classifyOnPack` step [3]:

```
1. classifier.classifyAsync(text)
     a. keywordIntent = first matching rule (raw text, all guards honoured)
     b. distribution  = model over the same text        <- ALWAYS runs
     c. arbitrate:
          no rule            -> (model label, model conf,  arbitration = nil)
          rule == model      -> (rule label,  model conf,  arbitration = .corroborated)
          rule != model      -> (rule label,  0.60,        arbitration = .contested)
2. help guard / polarity guard        (unchanged, already implemented)
3. calibratedConfidence re-read       (unchanged, already implemented)
4. fireBar = corroborated ? agreement : confidence
5. OOV guard
6. fire test: intent == fallback || conf < fireBar -> .fallback
7. confirmation gate -> slot filling
```

Steps 2, 3, 5, 6, 7 already exist and are correct. Only step 1 and the `fireBar` in
step 4 are new.

`CONTESTED_CONFIDENCE = 0.60` is carried verbatim from the reference and from
Android's `OfflineNluServiceImpl.contestedConfidence`. It is deliberately below
`thresholds.confidence` (0.70), which is what makes a contested keyword unable to fire
on its own. Do **not** re-derive it; the reference marks it PROVISIONAL pending an
out-of-fold sweep, and iOS inventing a second number would break parity by definition.

---

## 6. Change set

### 6.1 `Core/Models/IntentResult.swift` — carry the arbitration verdict

Add a nested enum and a **defaulted** property to `ClassificationResult`:

```swift
enum Arbitration: String, Sendable {
    case corroborated   // a keyword rule and the model named the same intent
    case contested      // they disagreed; the rule holds the label, 0.60 holds the number
}

let arbitration: Arbitration?   // nil = no keyword rule fired this turn
```

The explicit memberwise `init` (`IntentResult.swift:60`) gains
`arbitration: Arbitration? = nil` **as the last parameter with a default**.

> **Why this is the safety hinge.** `IntentClassifying` does not change. All five test
> stub actors construct `ClassificationResult` without the new argument, get `nil`, and
> therefore keep the flat bar — i.e. today's behaviour, exactly. Only
> `PackClassifierAdapter` ever sets it.

### 6.2 `Pack/Loader/PackEngineFactory.swift` — `PackClassifierAdapter` gains the keyword stage

`init(pack:)` (line 275) additionally stores:

- `keywordRules: [PackKeywords.Rule]` — from `pack.keywordRulesByTier` (**keep today's
  ordering**; see §12 VIK-057)
- `keywordStageEnabled: Bool` — `pack.stageEnabled(.keyword)`, decoded today and
  consumed nowhere. This is the OTA kill switch (§11).

Rules are compiled **once in `init`** into `NSRegularExpression`, not per turn — the
current engine compiles `trigger.regex` on every `range(of:options:.regularExpression)`
call. A rule whose pattern does not compile on this platform is **dropped with an
`os_log` error**, not fatal, matching `helpMarkers` handling in `NLUEngine.init` and
`NluTopicDeriver`'s carrier handling on Android.

`classifyAsync` becomes:

```
guard keywordStageEnabled else { <existing body, arbitration: nil> }

let kw = firstMatchingRule(rawText)          // all guards veto, not just guards.first
let prediction = await classifier.classify(text)

if prediction.isVacuous {
    // unchanged: out-of-scope, confidence 0, arbitration nil
    // a vacuous model cannot corroborate anything, and must not have its bar dropped
}
guard let kw else { <model label, model conf, arbitration: nil> }
if kw.intent == prediction.intent { <kw.intent, prediction.confidence, .corroborated> }
else                              { <kw.intent, Self.contestedConfidence, .contested> }
```

Two invariants worth stating in code comments:

- the keyword stage matches **raw** text (`classifier.py:247`); only the model path is
  normalised. iOS has no normaliser today (§12 VIK-056), so both currently see the same
  string — the comment prevents that from silently changing when VIK-056 lands.
- `lastDistribution` inside `PackIntentClassifier` is written by `classify(_:)`
  regardless of arbitration, so `calibratedConfidence(for:)` keeps working on a
  keyword-routed turn. This is the property Stage 0 destroyed and the reason the Stage 0
  help-guard workaround exists.

### 6.3 `NLU/Engine/NLUEngine.swift` — delete Stage 0, add the agreement bar

**Delete:**

- `matchKeywordTrigger(_:)` — lines 507-521
- the whole `if let kwIntent = matchKeywordTrigger(text) { … }` block — lines 543-583,
  including the `decisionLog.notice("help_guard stage0_declined …")` branch and its
  explanatory comment, which describes a problem that no longer exists

**Add:**

- `private let agreementThreshold: Double?` — a new `init` parameter, **defaulted to
  `nil`**, placed alongside `interruptThreshold`. `nil` means "never drop the bar",
  which is today's behaviour, so every existing `NLUEngine(...)` call site in the test
  suite compiles and behaves unchanged.
- immediately before the fire test at line 668:

```swift
let corroborated = result.arbitration == .corroborated
let fireBar = corroborated ? (agreementThreshold ?? schema.confidenceThreshold)
                           : schema.confidenceThreshold
```

and change line 668 to compare against `fireBar`.

**Deliberately unchanged:** the help/polarity guard, `calibratedConfidence` re-read,
the OOV guard, the confirmation gate, slot filling, `handleSlotFilling`'s VIK-038
topic-switch probe, and `assessSlotAnswer`. The guard must stay **after** arbitration
and **before** the fire test — that is the reference ordering
(`engine.py:1195` → `1244` → `1284` → `1293`) and Android's ([3] in
`OfflineNluServiceImpl`).

> **Ordering note (deliberate divergence, already documented at `NLUEngine.swift:650`):**
> Python runs the help guard before semantic rescue; iOS runs rescue inside
> `classifyAsync`. Moot while the pack disables the semantic stage. This change does
> not alter that, and the existing comment stays.

### 6.4 `Pack/Loader/PackEngineFactory.swift` — wire the threshold

`makeEngine` passes `agreementThreshold: pack.policies.thresholds.agreement`
(already decoded as `Double?`, `PackSections.swift:168`; `pack-en` carries `0.5`).

Log line gains the arbitration configuration so a field log can prove which build is
running:

```
agreement \(pack.policies.thresholds.agreement.map(String.init) ?? "off"),
keyword stage \(pack.stageEnabled(.keyword) ? "on" : "off")
```

### 6.5 `NLUSchema.keywordTriggers` — deprecate, do not delete

`PackEngineFactory.schema(from:)` line 247 keeps building it. Nothing reads it after
this change. **Leave it in place for one release**, marked:

```swift
/// DEPRECATED (VIK-055). The keyword stage now lives in `PackClassifierAdapter`,
/// mirroring `classifier.py`. This projection is lossy — it keeps only
/// `guards.first` — and must not be revived. Remove once no host reads `NLUSchema`.
```

Deleting it in the same PR would change `NLUSchema`'s memberwise init and force edits
in four test files for no behavioural reason. That is churn dressed as cleanup.

---

## 7. Non-breaking guarantees

Each of these is a property to verify, not an assertion of confidence:

1. **`IntentClassifying` is unchanged.** No conformer — production or test — needs an
   edit. Verified against the five stubs: `StubClassifier`, `GuardStubClassifier`,
   `FixedClassifier`, `ScriptedClassifier`, `ScriptedParityClassifier`,
   `TopicStubClassifier`.
2. **`ClassificationResult.arbitration` defaults to `nil`.** Stub-driven tests take the
   flat bar, i.e. today's path.
3. **`NLUEngine.agreementThreshold` defaults to `nil`.** Every existing
   `NLUEngine(...)` literal in the test suite compiles untouched and keeps the flat bar.
4. **`NLUResponse` is unchanged.** Five cases, same payloads. The host contract
   (`VoiceIntentSession`, `LiveTranscriptionViewModel`) does not move.
5. **`ConversationEngine` is unchanged.**
6. **No pack format change.** `agreement`, `stages.keyword` and `guards` are all
   already in `pack-en-v1.0.54` and already decoded.
7. **A pack without `agreement`** (older vendored pack) falls back to the flat bar
   rather than guessing — same discipline as `oovReject`/`oovBypass` being read as a
   pair or not at all.

---

## 8. Test impact matrix

Derived by reading each suite, not by running them. Every "changes" row is a required
edit in this PR.

| Suite | Today's route | After | Action |
|---|---|---|---|
| `ReferenceParityTests.testEngineDecisionsMatchTheReference` | 3 corroborated FULFILL cases collected into `divergences[]` and `print`ed | stubs still return `arbitration: nil`, so they still diverge | **Change.** The suite's own comment says: *"Those cases are reported, not asserted, until `thresholds.agreement` is implemented here — at which point the reporting below should become an assertion and this paragraph should go."* Script `arbitration` from the fixture into `ScriptedParityClassifier`, turn the `divergences` block into `XCTFail`, delete the paragraph. **This is the acceptance criterion for VIK-055.** |
| `ConfirmationAndSlotFlowTests.testTheTwoUtterancesTakeTheRoutesTheseTestsAssume` | asserts `keywordRouted` matches a rule and `classifierRouted` does not | premise still true | **Keep.** Reword the "must reach Stage 0" message to "must reach the keyword stage". |
| `…testAKeywordRoutedAlwaysGatedIntentStillConfirms` (VIK-036) | Stage 0 → gate at confidence 1.0 | adapter is stubbed out, so the stub's label+0.99 drives it; `Cmd.SendMessage` is `always` → still `.confirm` | **Keep.** Add a comment that the stub now replaces the keyword stage, so this asserts the gate, not the route. |
| `…testConfidentReminderSkipsConfirmationAndCollectsSlots` | Stage 0 with `keywordRouted` | stub returns `reminder` @0.95 → same `.prompt`, same `filled["name"]` | **Keep, unchanged.** |
| `HelpMarkerGuardTests.testAKeywordRoutedHelpAskIsNotSmuggledPastTheGuard` | asserts Stage 0 does not smuggle a help ask past the guard | Stage 0 is gone; stub returns the help label at ≥0.70 → still `.fulfill(help)` | **Keep, but re-point.** The test would pass vacuously. Move the premise to the new seam: drive it through a real `PackClassifierAdapter` (§9.3) so it proves the *arbitration* path honours the guard. |
| `HelpMarkerGuardTests` — the other 6 tests | classifier path | unchanged | **Keep, unchanged.** |
| `OpenSlotNameDerivationTests` (`openReminder = "set a reminder"`) | Stage 0 | `FixedClassifier` routes to `reminder` → same `.prompt` for `name` | **Keep.** Update the comment at line 165 ("Hits the Stage-0 keyword rule"). |
| `TopicDerivationParityTests`, `PackDateTimeParityTests`, `PackSlotResolverTests`, `PackEntityAndClassifierTests` | no keyword involvement | unchanged | **Keep, unchanged.** |
| `PackLoadingTests` (asserts `pack.stageEnabled(.keyword)`) | premise only | now actually consumed | **Keep.** |
| `VoiceIntentSessionSmokeTests`, `VoiceIntentClientTests` | facade | `NLUResponse` unchanged | **Keep, unchanged.** |

Net: **2 suites change behaviourally** (`ReferenceParityTests`, one
`HelpMarkerGuardTests` case), 4 get comment/message updates, the rest are untouched.

---

## 9. New tests

### 9.1 `KeywordArbitrationTests` (new file)

Driven by a **real** `PackClassifierAdapter` over the vendored pack, not a stub —
otherwise the arbitration code is never executed by the suite.

- `testContestedKeywordDoesNotFire` — the regression case.
  `"who is the prime minister of create reminder"` → `.fallback`. Premises asserted,
  not assumed: (a) a keyword rule claims it and names `reminders.add`; (b) the model's
  top-1 is not `reminders.add`.
- `testCorroboratedKeywordUsesTheModelConfidence` — `"turn up the volume"` →
  `.fulfill(Cmd.VolumeIncrease)` at the model's number, not 1.0 and not 0.60.
- `testCorroboratedTurnBelowFireBarStillFires` — `"turn it up its too quiet"`, which
  the fixture records at 0.6922 → FULFILL, because the bar drops to `agreement` 0.50.
  This is the case iOS gets wrong today in the *opposite* direction.
- `testNoKeywordRuleLeavesArbitrationNil` — `"remind me to go to the airport"`.
- `testKeywordStageDisabledSkipsArbitration` — pack copy with
  `stages.keyword.enabled = false`; asserts pure-model routing. Proves the kill switch.

### 9.2 Pack-invariant guards

- `testNoKeywordRuleShipsMoreThanOneGuard` — records the assumption that made §12
  VIK-058 safe to close incidentally. If a future pack ships two guards, this test says
  so instead of the behaviour changing silently.
- `testEveryKeywordRulePatternCompilesOnThisPlatform` — `NSRegularExpression` is not
  Python's `re`; a pattern that fails here drops a rule silently. Same discipline as
  `HelpMarkerGuardTests.testTheMarkerPatternCompilesOnThisPlatform`.

### 9.3 `HelpMarkerGuardTests` — one case re-pointed

Rewrite `testAKeywordRoutedHelpAskIsNotSmuggledPastTheGuard` to build the engine with a
real `PackClassifierAdapter`. All five utterances in its table match a keyword rule
**and** carry a help marker, so this becomes the arbitration-path proof that ND-14
still holds. Expected outcome per utterance must be **read off the model**, not
asserted from memory — e.g. `"how do i set a reminder"` is corroborated-or-contested
depending on what the head says, and the test should record which.

### 9.4 Parity fixture — regenerate

`Fixtures/parity_expectations.json` currently carries **6** `fire_boundary` cases:
4 `corroborated`, 2 with no keyword rule. **Zero contested cases.** The defect class
this plan fixes is unrepresented in the fixture.

Regenerate with contested probes included:

```
PYTHONPATH=packages/runtime python -m scripts.ci.emit_parity_fixtures \
    --lang en --out VoiceAIKit/Tests/VoiceAIKitTests/Fixtures/parity_expectations.json
```

Add at minimum `"who is the prime minister of create reminder"` and one contested case
per keyword-bearing capability. If the emitter cannot yet produce contested probes,
that is a Python-side task and a **blocker for closing VIK-055**, not something to
approximate by hand in Swift — that is the failure mode the fixture exists to prevent.

---

## 10. Validation gates

Merge requires all of:

1. `swift test` green on the full suite.
2. `ReferenceParityTests` asserting (not printing) every `fire_boundary` case,
   including new contested probes.
3. **Holdout re-measurement** on `holdout_honest.csv` (n=1470) through the iOS path,
   compared against the pre-change run on the same build:
   - `wrong_action_count` must not increase (pack meta records 28).
   - gate-pass rate reported; a drop is acceptable only where the turns that stopped
     passing are contested ones — that is the fix working.
   - per-utterance diff list attached to the PR.
4. `PerformanceBenchmarks` — the extra inference runs on the ~9% of turns that hit a
   keyword rule; the reference measured 0.06 ms for that arm. On-device the cost is one
   `PackIntentClassifier.classify` (~1 ms CPU-only). Record before/after p50 and p95 for
   a keyword-routed utterance. **Regression budget: +3 ms p95.**
5. A device smoke run of the five utterances in §9.3 plus the regression case, with
   `log stream --predicate 'subsystem == "com.voiceaikit"'` captured in the PR.

Add one `decisionLog.notice` at the arbitration site carrying
`model=<label>/<conf> keyword=<intent|-> arbitration=<…> final=<label> conf=<…> bar=<…>`
— the same shape as Android's `Timber.i("[NLU] decide …")`, so the two platforms'
field logs can be diffed line for line. No transcript in the log line, matching the
existing privacy discipline (`OfflineNluServiceImpl.tokenCount` comment).

---

## 11. Rollback

Two independent levers, in order of preference:

1. **OTA, no app update.** Ship a pack with `runtime/stages.json`
   `{"id":"keyword","enabled":false}`. The adapter then skips the keyword stage
   entirely and routes on the model alone — 90.20% holdout accuracy on the full head,
   a known and measured degradation rather than an unknown one. This lever only exists
   *after* §6.2 consumes `stageEnabled(.keyword)`, which is part of why it is in scope.
2. **Build rollback.** Revert the PR. Because `arbitration` and `agreementThreshold`
   are both defaulted-nil additions, a partial revert of §6.3 alone also degrades
   cleanly to the flat bar without a compile break.

There is deliberately **no host-facing feature flag**. A boolean on the public facade
would become a permanent second code path that nothing measures.

---

## 12. Deferred divergences — verified, not in this change

All of these were confirmed against source in the same audit. Each needs its own
ticket, measurement and PR. **None of them is the cause of the reported defect.**

> The canonical, both-directions backlog lives in
> [`things-to-pull-from-android.md`](./things-to-pull-from-android.md) — including what
> **Android** should pull from iOS, and the asymmetries that are correct and must not be
> "fixed". The table below is the subset that touches the files this plan edits.

| ID | Divergence | Evidence | Why deferred |
|---|---|---|---|
| **VIK-056** | **No text normalisation on iOS.** Android runs `NluTextNormalizer` (contraction expansion, apostrophe unification, whitespace collapse) before `classify` — "the vocabulary was fitted on normalized text". iOS decodes `lexicon.contractions` (`PackLexicon.swift:32`) and **never applies it**; `PackTFIDFVectorizer` only lowercases. `"don't remind me"` → Android `do not remind me`, iOS `dont remind me` → different features, different confidence, silently. | `PackLexicon.swift:32,39,55` are the only references to `contractions` in the whole Swift tree. Python: `text_norm.py::normalize_text`, called from `classifier.py::_model_distribution`. | **This changes the model input on every single turn.** It requires a full holdout re-measurement and its own gate-pass comparison, and it must land with the keyword-stage-matches-raw-text invariant (§6.2) already in place. Mixing it into VIK-055 would make any accuracy delta unattributable. **Highest-value remaining parity gap.** |
| **VIK-057** | **Keyword rule precedence.** Android matches in **file order**, first match wins — `NluKeywordMatcher` doc: *"the order is part of the pack's meaning"*. iOS `keywordRulesByTier` (`ResolvedPack.swift:159`) re-sorts by tier, then by **intent name alphabetically**. Within a tier a different rule can win. | `NluKeywordMatcher.match` vs `ResolvedPack.keywordRulesByTier` | Needs a per-utterance sweep over the pack to find where the two orders actually disagree before changing either. §6.2 keeps today's iOS ordering so this PR introduces no second behaviour change. |
| **VIK-058** | **Guard arity.** Android vetoes on **any** guard (`guards.map(::Regex)`). iOS keeps only `guards.first` (`PackEngineFactory.swift:249`). | Verified: no rule in `pack-en-v1.0.54` ships more than one guard, so latent today. | **Incidentally closed by §6.2**, which reads `PackKeywords.Rule` directly. Zero behaviour delta on this pack; §9.2 adds the invariant test so it stays that way. Keeping the ID for traceability. |
| **VIK-059** | **Android has no OOV guard**, though the pack ships `oov_reject`/`oov_bypass` and iOS implements it. The inverse of this plan's gap. | `OfflineNluServiceImpl.classifyOnPack` has no ratio check; `policies.thresholds` carries both keys. | Android-side ticket. Raise with that team; not an iOS change. |
| **VIK-060** | **Temperature asymmetry.** Android reads `temperature` (0.671457, the ONNX/Python value); iOS reads `temperature_coreml_full` (0.54399). Per-backend correct, but the same utterance carries a different confidence on the two platforms against the same 0.70 bar. | `calibration.json` in both packs; `NluManager.temperature` vs `ClassifierVariant.temperatureKey` | Not a bug — but it means cross-platform log comparison must never compare confidences directly. Document in the runbook; no code change. |
| **VIK-061** | **No ASR biasing.** Android derives literal phrases from the pack's keyword regexes (`NluBiasingDeriver`, 207 lines — top-level `\|` split, group expansion, bail-out on unreadable shapes, bounded and deduplicated) and feeds them to the recognizer via `RecognizerIntent.EXTRA_BIASING_STRINGS`. iOS sets no `contextualStrings` anywhere. | `NluBiasingDeriver.kt`; `SpeechManager.kt:743`; nothing in `Core/Recognition/SpeechRecognitionService.swift` | **Should land BEFORE this plan.** It sits upstream of the NLU entirely — a misheard transcript defeats arbitration and model alike — and carries zero parity risk, so it also de-noises VIK-055's holdout measurement. Separate PR because it touches the speech layer, not the NLU. |
| **VIK-062** | **Polarity guard decoded, never wired.** `PackGuards.polarity` is decoded; `PackEngineFactory.makeEngine` passes only `helpMarkerPattern` and `helpPairs`. Android implements `applyPolarityGuards`, including abstention when both directions are present. | `PackSections.swift:305, 315, 330` vs `PackEngineFactory.swift:117-118`; `NluGuards.kt` | Latent — the pack ships zero polarity rules. But it is the **third** decoded-and-unused pack field in this audit, after `agreement` (this plan) and `contractions` (VIK-056). Fix with a contract test, not just a wire-up. |
| **VIK-063** | **No per-turn decision log.** Android emits one line carrying every input to the decision: `model=%s/%.2f keyword=%s corroborated=%b guard=%s->%s final=%s conf=%.2f bar=%.2f`. iOS logs only on a help-guard redirect, so a routing complaint cannot be attributed to a stage. | `OfflineNluServiceImpl.kt:101` vs `NLUEngine.swift:551, 615` | **Not deferred — already in scope**, §10 of this plan. Listed for traceability; it has standalone value and could ship first. |
| **VIK-064** | **Whole-pack rejection vs per-intent quarantine.** iOS validation *coverage* is equal or better (it checks slot prompts, slot entities, actions against the capability-owned map, confirmation branches, and label-set/intent-set equality). The difference is granularity: one dangling key throws and rejects the entire pack, where Android quarantines that intent and keeps the other 56. | `BundleDataLoader.swift:296-340, 371-380` vs `NluPackValidator.kt`, `NluPackValidation` | Correct for the OTA path — iOS can throw because staging + smoke test + `.rollback_target` keep the previous pack. The seed-pack exposure is **already largely covered**: `PackLoadingTests.testVendoredPackLoads` / `testEveryReferencedKeyResolves` load it through the real `BundleDataLoader` in CI. Lowest priority of the set. |
| **VIK-065** | **Classifier self-warmup.** Android runs `runCatching { classifyInternal(WARMUP_TEXT) }` at the end of `OnnxIntentClassifier.init`. iOS's `warmUp()` is correct but host-invoked; a host that forgets makes the user pay the ~15 ms CoreML load on their first utterance. | `OnnxIntentClassifier.kt:68` vs `PackIntentClassifier.warmUp()` | Arguably iOS is right to leave it to the host — it has a real memory story (`unload()`). Decide deliberately: warm in the factory, or assert the host step in the smoke tests. |
| **VIK-066** | **(Android-side)** A day with no clock time is lost. `SysDateTimeParser.parse` returns `null` without a time-of-day and nothing parks the day, so `"remind me Friday"` → `"6am"` resolves against today. iOS parks the day at local midnight and anchors the later bare time to it. | `SysDateTimeParser.kt:33` vs `NLUEngine.resolveDateTime` | Android ticket, like VIK-059. No iOS change. |

---

## 13. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Turns that fire today start falling back | **Expected, by design** | Contested keyword turns route to fallback/GenAI | This is the fix. §10.3 bounds it: `wrong_action_count` must not rise; the utterances that stop firing must be contested ones, listed per-PR. |
| A corroborated turn that used to fire now falls back | Low | Regression | The bar *drops* to 0.50 for corroborated turns, so a turn that fired at confidence 1.0 still fires. `testCorroboratedTurnBelowFireBarStillFires` covers the widened band. |
| Latency on keyword-routed turns | Medium | ~9% of turns gain one inference | §10.4 budget. `PackIntentClassifier` is `.cpuOnly` and measured at ~1 ms. |
| `NSRegularExpression` rejects a pack pattern that Python accepts | Low | A rule silently stops firing | §9.2 compile test; §6.2 logs a dropped rule at error level rather than trapping. |
| Working-tree collision | **High — active now** | Merge conflict / lost work | §14. |
| Parity fixture cannot emit contested cases | Medium | VIK-055 cannot be closed on evidence | Raise on the Python side before starting §9.4. Do not hand-author expectations in Swift. |

---

## 14. Sequencing

**Before any code is written**, resolve the working-tree state. At the time of writing:

```
branch: fix/ota-unification-and-concurrency-Architecture-Refactor-plan-imp-Porting-Python-logic
 M VoiceAIKit/Sources/VoiceAIKit/NLU/Engine/NLUEngine.swift            (+175/-34 uncommitted)
 M VoiceAIKit/Sources/VoiceAIKit/NLU/Engine/NLUProtocols.swift
 M VoiceAIKit/Sources/VoiceAIKit/Pack/Loader/PackEngineFactory.swift
 M VoiceAIKit/Sources/VoiceAIKit/Pack/Loader/PackIntentClassifier.swift
 M VoiceAIKit/Sources/VoiceAIKit/Pack/Schema/ResolvedPack.swift
?? VoiceAIKit/Tests/VoiceAIKitTests/HelpMarkerGuardTests.swift
```

These are **the same five files this plan edits**, and the untracked test file is the
in-flight ND-14 work. Land or stash that first. Starting VIK-055 on top of an
uncommitted 211-line diff in the same files is how a good fix gets blamed for someone
else's regression.

Then, in order:

| PR | Contents | Gate |
|---|---|---|
| 0 | Land the in-flight ND-14 / help-guard work on its own | existing suite green |
| 1 | §9.4 — regenerate the parity fixture with contested probes (Python side if needed) | fixture contains ≥1 contested case |
| 2 | §6.1 + §6.2 + §6.3 + §6.4 + §6.5, §8 edits, §9.1-9.3 | §10 gates 1-5 |
| 3 | VIK-057 rule-order sweep, or VIK-056 normalisation — **not both** | own measurement |

PR 2 is the only one that changes runtime behaviour, and it changes exactly one thing.

---

## Appendix — source anchors

| What | Where |
|---|---|
| iOS Stage 0 bypass | `NLU/Engine/NLUEngine.swift:507-521, 543-583` |
| iOS fire test | `NLU/Engine/NLUEngine.swift:659-670` |
| iOS help guard + confidence re-read | `NLU/Engine/NLUEngine.swift:600-615` |
| iOS classifier adapter | `Pack/Loader/PackEngineFactory.swift:265-330` |
| `agreement` decoded, unused | `Pack/Schema/PackSections.swift:168, 191` |
| Lossy keyword projection | `Pack/Loader/PackEngineFactory.swift:247-251` |
| Android arbitration | `OfflineNluServiceImpl.kt` step `[3]`, `contestedConfidence = 0.60` |
| Android keyword matcher | `nlupack/NluKeywordMatcher.kt` |
| Android normaliser | `nlupack/NluTextNormalizer.kt` |
| Python reference arbitration | `nlu_engine/classifier.py::classify`, `CONTESTED_CONFIDENCE` |
| Python reference fire bar | `nlu_engine/engine.py:1244-1245, 1293` |
| VIK-055 acceptance criterion | `Tests/VoiceAIKitTests/ReferenceParityTests.swift:198-230` |
