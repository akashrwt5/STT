# Things to pull from Android

**Status:** backlog, evidence-backed
**Scope:** `VoiceAIKit` (iOS, Swift) vs `voiceaikit` (Android, Kotlin), both on `pack-en-v1.0.54`
**Companion:** [`VIK-055-keyword-arbitration-plan.md`](./VIK-055-keyword-arbitration-plan.md) — shipped; its §13 carries the holdout measurement
**Method:** every row below was read off source on both sides. Nothing here is inferred from docs, comments-as-spec, or assumed parity.

---

## 0. Why this document exists

The two runtimes are ports of the same Python reference
(`IntentClassifier/packages/runtime/nlu_engine`). They have drifted in both
directions. A cross-platform defect report tends to collect only the direction
someone noticed this week, which turns into "make iOS like Android" — and that
would be wrong, because iOS is ahead on more surface than Android is.

So this document is the **whole** delta, both directions, with the evidence for
each. §1 is what iOS should pull. §2 is what Android should pull. §3 is the
architectural asymmetry that is **correct** and should not be "fixed".

Pack content is not implicated anywhere in this document. A full tree hash of
both packs differs only in platform model artifacts (`model.onnx` vs
`.mlmodelc` + weights JSON), the per-backend temperature keys in
`calibration.json`, `bundle.json` and the integrity manifest. `keywords/en.json`,
`workflows.json`, `lexicons/en.json` and `runtime/policies.json` are
byte-identical.

---

## 1. iOS should pull from Android

Ordered by what I would actually do first, not by severity.

### Priority table

| ID | Item | Effort | Parity risk | Status |
|---|---|---|---|---|
| **VIK-061** | ASR biasing from the pack's keyword rules | M | None to the NLU — but the **delivery mechanism is unverified** on this API | **[Planned, spike-gated](./VIK-061-asr-biasing-plan.md)** |
| **VIK-055** | Keyword arbitration — **shipped THREE-way, not two** | M | High — a behaviour change, measured | **Shipped.** iOS now DIVERGES from Python/Android on purpose — see VIK-072 |
| **VIK-063** | Per-turn decision log | S | None | **Shipped** with VIK-055 |
| **VIK-062** | Polarity guard never wired to the engine | S | None today (pack ships 0 rules) | Not started |
| **VIK-065** | Classifier self-warmup on construction | S | None | Not started |
| **VIK-056** | Text normalisation before classification | M | **High** — changes model input on every turn | Not started |
| **VIK-064** | Per-intent quarantine instead of whole-pack rejection | L | Medium — changes load-failure semantics | **Largely mitigated by CI** — see below |
| **VIK-057** | Keyword rule precedence (file order vs tier-sort) | S | Medium — needs a sweep first | Not started |
| **VIK-058** | Guard arity (`guards.first` vs all guards) | S | None on this pack | **Closed** incidentally by VIK-055 §6.2 |

---

### VIK-061 — ASR biasing from the pack's keyword rules

**Android has it.** `nlupack/NluBiasingDeriver.kt` (207 lines) parses each keyword
regex into the literal phrases it can produce — splitting on top-level `|` while
ignoring `|` inside groups, expanding alternation groups into a slot product,
treating `\b`, `^`, `$` as contributing no text and `\s`/`\s+`/`\s*` as one
space — and **abandons a branch the moment it leaves the shape it understands**,
because a wrong hint actively hurts. Output is deduplicated and bounded
(`MAX_PER_PATTERN`, `MAX_TOTAL`).

Delivered to the recognizer at `speech/SpeechManager.kt:743`:

```kotlin
putExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, biasingPhrases)
```

Failure is soft: `OfflineNluServiceImpl.biasingPhrases()` wraps the derivation in
`runCatching` and returns `emptyList()` — an unreadable pack must never fail the
turn.

**iOS does not have it**, and the way to add it is **not** the obvious one.
`SpeechRecognitionService.swift` does not use `SFSpeechRecognizer` at all — it is
built on the iOS 26 `SpeechAnalyzer` + `SpeechTranscriber` API. On that API, Apple
documents the biasing path (`AnalysisContext.contextualStrings`) on
**`DictationTranscriber`**, which carries an explicit "Improve accuracy" section;
`SpeechTranscriber` has no contextual-strings or content-hint surface at all, and
an Apple developer-forums answer states it does not take contextual strings into
account. `SpeechAnalyzer.setContext(_:)` exists and is callable regardless of
module — so the call is legal, but on the documentation it is probably a no-op for
the module this app uses.

**Why it still matters.** It sits **upstream of every other item in this
document.** If the recogniser hears "creed a reminder", the keyword rule misses,
the model misses, and no amount of arbitration correctness recovers the turn.

**Why it is no longer unconditional P1.** An earlier draft of this document put it
ahead of VIK-055, on the assumption that iOS would set
`SFSpeechRecognitionRequest.contextualStrings`. That assumption was wrong for this
codebase. VIK-061 is now **spike-first**: a timeboxed measurement decides whether
there is a change to make at all, and which of three routes it is
(`AnalysisContext` on the current transcriber / switch to `DictationTranscriber` /
post-ASR lexical repair inside the kit). **VIK-055 is the one to start.**

**The deriver is worth building regardless.** `PackBiasingDeriver` — a direct port
of `NluBiasingDeriver` — is pure string work with no Speech dependency, and every
candidate route consumes its output. Two things to keep from the Kotlin: the
**bail-out on unrecognised regex shapes** (a wrong hint actively hurts) and the
**bounds** (12 per pattern, 120 total, 64-combination cross product, 4-character
minimum). Port it with a **parity fixture emitted from the Kotlin side**, not as a
rewrite — the `TopicDerivationParityTests` precedent applies: two suites written
independently agree until someone changes one of them.

Full detail, including the spike design and decision rule:
[`VIK-061-asr-biasing-plan.md`](./VIK-061-asr-biasing-plan.md).

---

### VIK-063 — Per-turn decision log

**Android has it.** One line per turn, carrying every input to the decision
(`OfflineNluServiceImpl.kt:101`):

```
[NLU] decide model=%s/%.2f keyword=%s corroborated=%b guard=%s->%s final=%s conf=%.2f bar=%.2f
```

The transcript itself is never logged — `tokenCount()` exists specifically so a
log line can say "three words where the user said nine" without recording what
they were.

**iOS does not.** `decisionLog` fires on exactly two branches, both help-guard
(`NLUEngine.swift:551` and `:615`). Every other turn leaves no record of *why* a
label was chosen. A routing complaint from the field currently cannot be
attributed to the keyword stage, the model, a guard, or the fire bar.

**Action.** Emit the same fields, in the same order, at the arbitration site.
Already specified in [VIK-055 §10](./VIK-055-keyword-arbitration-plan.md); listed
here because it has standalone value and could ship first. Keep Android's field
order verbatim so the two platforms' logs diff line for line — and keep the
transcript out, matching both the Android discipline and the existing
`privacy: .public` convention on intent names only.

---

### VIK-062 — Polarity guard decoded, never wired

**Android has it.** `NluGuards.applyPolarityGuards` — when a rule's pattern is
present and contradicts the predicted intent, the intent is redirected; when both
directions are present it **abstains**, because the signal is contradictory. Only
redirects into an intent the bundle actually knows.

**iOS decodes it and drops it.** `PackGuards.polarity` is decoded at
`Pack/Schema/PackSections.swift:305, 315, 330`. `PackEngineFactory.makeEngine`
passes only `helpMarkerPattern` and `helpPairs` to `NLUEngine`
(lines 117-118). There is no polarity code path in the engine at all.

**Latent today** — the shipping pack declares zero polarity rules, and Android's
own comment says so. But this is the **third** decoded-and-unused pack field
found in one audit:

| Field | Decoded at | Consumed |
|---|---|---|
| `policies.thresholds.agreement` | `PackSections.swift:168` | nowhere (VIK-055) |
| `lexicon.contractions` | `PackLexicon.swift:32` | nowhere (VIK-056) |
| `guards.polarity` | `PackSections.swift:305` | nowhere (VIK-062) |

Three instances is a pattern, not three accidents. **Recommended alongside the
fix:** a `PackContractTests` case that asserts every decoded pack field has at
least one production read — or, more practically, an explicit allow-list of
"decoded but deliberately unmodelled" fields, the way
`PackSections.swift:257-293` already does for `runtime/routing.json`. That file
is the good example: routing is decoded nowhere *and says why, at length*. The
three above say nothing.

---

### VIK-065 — Classifier self-warmup

**Android.** `OnnxIntentClassifier.init` ends with
`runCatching { classifyInternal(NluConstants.WARMUP_TEXT) }` — deliberately last,
after every property is assigned, and swallowing failure.

**iOS.** `PackIntentClassifier.warmUp()` exists and is correct (loads the head,
runs one throwaway prediction, ~15 ms on `.cpuOnly`) but must be called by the
host. If the host forgets, the user pays the load on their first utterance.

**Action.** Either call `warmUp()` from `PackEngineFactory.makeEngine` (a
`Task { await classifier.warmUp() }` hop, since `makeEngine` is not async), or
document it as a required host step and assert it in `VoiceIntentSessionSmokeTests`.
The second option is arguably better: iOS has a real memory story
(`unload()`/`releaseStage3()`) and an unconditional warm-up in the factory takes
that choice away from the host.

---

### VIK-056 — Text normalisation before classification

**Android.** `NluTextNormalizer` runs before `classify`: lowercase, unify
apostrophe variants, expand contractions via the pack's table (longest-first
alternation so a key that prefixes another cannot shadow it), strip remaining
apostrophes, collapse whitespace. Its doc: *"Port of
`packages/runtime/nlu_engine/text_norm.py::normalize_text`… must stay
behaviourally identical to the Python and Swift ports."* The last clause is
aspirational — there is no Swift port.

**iOS.** `PackTFIDFVectorizer.tokenize` lowercases and splits on non-word
characters. `lexicon.contractions` is decoded and never applied.

**Effect.** `"don't remind me"` → Android `do not remind me`, iOS `dont remind me`.
Different tokens, different bigrams, different TF-IDF vector, different
confidence — against the same 0.70 bar. Silent on both sides.

**Why it is not in the VIK-055 PR.** This changes the model input on **every**
turn, not on the ~9% that hit a keyword rule. It needs its own holdout
re-measurement and its own gate-pass comparison. Landing it with VIK-055 would
make any accuracy delta unattributable between the two changes.

**Ordering constraint.** It must land **after** VIK-055, because VIK-055 §6.2
establishes the invariant that *the keyword stage matches raw text and only the
model path is normalised* (`classifier.py:247`). Today both see the same string,
so the invariant is invisible; the moment normalisation lands it becomes
load-bearing.

**This is the highest-value remaining parity gap after VIK-055.**

---

### VIK-064 — Per-intent quarantine instead of whole-pack rejection

**First, the correction that matters.** iOS validation *coverage* is not weaker.
`BundleDataLoader.swift:296-340, 371-380` checks completion response keys,
completion actions against the capability-owned action map, confirmation prompts,
both confirmation branches (response **and** action), every slot's prompt key,
every slot's entity, model-label-set vs pack-intent-set **equality**, the cascade
output dimension against the label count, and dangling help-guard pairs. That is
a superset of some of Android's checks — the label-set equality check in
particular. (`PackEngineFactory.swift:184`'s `?? ""` is unreachable: the loader
has already thrown.)

The difference is **failure granularity**:

| | iOS | Android |
|---|---|---|
| Bad shape (no intents, no thresholds, label-set mismatch) | throw → pack rejected | `isUsable = false` → every turn falls back |
| One intent with a dangling response key | throw → **whole pack rejected** | `brokenIntents += intent` → that intent falls back, other 56 work |
| Dangling help-guard pair | throw → pack rejected | **warning only** — `NluGuards` abstains on an unknown sibling, so it degrades to "no redirect" |

Android: `NluPackValidator.validate(...) -> NluPackValidation(isUsable, brokenIntents)`,
read on the turn path as two O(1) lookups (`NluManager.getWorkflow` returns null
for a broken intent → fallback).

**Where this bites iOS.** The OTA path is fine — see §4. The exposure is the
**seed pack**: `VoiceAISeedPackEN` is vendored into the binary, and if one intent
in it carries one dangling key, `BundleDataLoader.load` throws and the device has
**no NLU at all**, with 56 healthy intents sitting on disk.

**The cheap mitigation already exists.** `PackLoadingTests.testVendoredPackLoads`
and `testEveryReferencedKeyResolves` load the vendored seed pack through the real
`BundleDataLoader` (`PackTestSupport.loadPack`), and `testLabelSpaceMatchesIntentSet`
asserts the label/intent equality. So a seed pack with a dangling key **fails CI, not
the device**. That is the outcome per-intent quarantine would have bought, obtained
more cheaply.

**Which drops this to the bottom of the backlog.** The remaining exposure is narrow:
a pack that passes CI but fails to load on device — i.e. a platform-specific
`NSRegularExpression` rejection, or a CoreML artifact that binds in CI and not on a
given OS version. Both are better addressed directly than by a general quarantine
mechanism.

**If it is still wanted later:** split `VoiceIntentError` load failures into fatal vs
per-intent, carry `brokenIntents: Set<String>` on `ResolvedPack`, and have `NLUEngine`
route those to `.fallback`. Note this weakens a currently strong guarantee — "a
loaded pack is wholly valid" — so it needs a deliberate decision, not a drive-by
change.

---

### VIK-057 — Keyword rule precedence

**Android** matches in **file order**, first match wins. `NluKeywordMatcher`'s
doc: *"One ordered list, first match wins — the order is part of the pack's
meaning."*

**iOS** re-sorts: `ResolvedPack.keywordRulesByTier` orders by `tier`, then by
**intent name alphabetically** (`ResolvedPack.swift:159-164`). Within a tier a
different rule can win.

Needs a per-utterance sweep over the pack to find where the two orders actually
disagree before changing either side. VIK-055 §6.2 deliberately preserves today's
iOS ordering so that PR introduces no second behaviour change.

---

### VIK-058 — Guard arity

**Android** vetoes on **any** guard: `guardRegexes.none { it.containsMatchIn(text) }`.

**iOS** keeps only the first: `KeywordTrigger(notRegex: $0.guards.first)`
(`PackEngineFactory.swift:250`).

Verified latent: no rule in `pack-en-v1.0.54` ships more than one guard.
**Closed incidentally by VIK-055 §6.2**, which reads `PackKeywords.Rule` directly
instead of the lossy `KeywordTrigger` projection — zero behaviour delta on this
pack. VIK-055 §9.2 adds the invariant test so a future two-guard rule fails loudly
instead of silently half-applying.

---

## 2. Android and Python should pull from iOS — and two iOS gaps vs the reference

Raise these with the Android team. They are listed here so this document is the
single cross-platform delta rather than a one-directional complaint.

| ID | Item | Evidence |
|---|---|---|
| **VIK-059** | **No out-of-vocabulary guard.** The pack ships `oov_reject: 0.25` and `oov_bypass: 0.97`; Android's `OfflineNluServiceImpl.classifyOnPack` never computes a ratio. iOS implements it and the reference documents why the ratio alone is insufficient (`'send a message to john'` is 25% OOV and entirely real). This is Android's own decoded-and-unused field. | `runtime/policies.json` vs `OfflineNluServiceImpl.kt` |
| **VIK-066** | **A day without a clock time is lost.** `SysDateTimeParser.parse` returns `null` when no time-of-day is found — by design ("tomorrow alone would become midnight"). But nothing parks the day, and `OfflineNluServiceImpl` holds no cross-turn state, so `"remind me Friday"` → *"When should I remind you?"* → `"6am"` resolves against **today**, and Friday is gone. iOS parks the day at local midnight in `session.partialDateTime` and anchors the later bare time to it (`NLUEngine.resolveDateTime`). | `SysDateTimeParser.kt:33`, `NLUEngine.swift:~810` |
| **VIK-072** | **iOS now runs a THIRD arbitration variant, on purpose.** Python and Android split keyword-vs-model two ways (agree / disagree). iOS splits three: the model only overrules a rule when it answers OUT OF SCOPE; a model naming a different in-scope intent loses to the rule. Measured on `holdout_honest.csv` (n=1470) through the reference's own ladder: two-way costs 10 correct turns, three-way costs 1, both fix the defect, neither changes `wrong_action_count`. **This is a deliberate divergence and it is debt** — exactly the shape that produced VIK-050, VIK-055 and VIK-056, where one runtime moved and nobody wrote it down. `G_oos` has been added to `scripts/analysis/arbitration_holdout.py` so the other runtimes can reproduce the number rather than take iOS's word for it. Next step is a Python-side decision; Android follows Python. | `VIK-055-keyword-arbitration-plan.md` §13; `scripts/analysis/arbitration_holdout.py` |
| — | **No dialog state machine in the kit.** Android's kit exposes `classifyIntent` / `resolveFollowUpSlot` / `resolveConfirmation` and leaves session contexts, context lifespans, the `max_slot_attempts` budget and topic-switch detection to the host. iOS owns all of it, including the VIK-038 insight that a topic-switch probe must be gated on the awaited **entity kind** — open and date-time slots never probe, because a slot answer is out-of-distribution input for a command classifier and its confidence is not a thresholdable quantity. If the Android host reimplements this, it should reimplement *that* rule too. | `IOfflineNluService.kt` vs `NLUEngine.handleSlotFilling` |
| — | **Binary endpointing window.** `ByteVad.useSlotAnswerWindow(Boolean)` — slot answer or not. iOS assesses three ways (`.complete` / `.freeform` / `.incomplete`) using the awaited slot's entity kind plus a trailing-function-word check, so "tomorrow… …5 AM" and "drink… …water" do not split into two turns. | `ByteVad.kt:114` vs `NLUEngine.assessSlotAnswer` |
| **VIK-067** | **(iOS gap vs the Python reference, not vs Android)** No "does this answer the awaited slot?" guard before the topic-switch probe. `"Mute"` is a `memory` entity value *and* a tier-1 keyword rule, so answering the memory prompt with "mute" mutes the device. The reference refuses to interrupt when the utterance is a valid value for the awaited closed slot. Android has no slot state machine at all, so it cannot have this bug — or this guard. | `engine.py:878-946` |
| **VIK-068** | **(same)** No cancellation cue mid-slot-flow — no "cancel" / "never mind" / "stop". The only exit is exhausting `max_slot_attempts`. The reference has `cancel_cues` + `_is_cancel`, with a purity guard so "no, tomorrow at 5" reads as a correction. | `engine.py:242-244, 862+` |
| — | **No confidence margin and no vacuous-prediction check.** iOS reports `margin` (gap to runner-up) and `isVacuous` (no feature matched, so every logit is its intercept and the softmax is meaningless while still able to clear 0.70). Android's `IntentPrediction` carries the full distribution but neither derived signal. | `PackIntentClassifier.Prediction` vs `IntentPrediction.kt` |

---

## 3. Shared gaps — no runtime owns this one

### VIK-070 — `contestedConfidence` is a code constant on all three runtimes

**The rule this breaks.** This codebase has an explicit, earned pattern: *a number
that changes a decision must be content-owned.* VIK-050 is the case that
established it. `NLUEngine` carried
`private static let interruptThreshold: Double = 0.75`, documented as mirroring
Python — but 0.75 is Python's FALLBACK for a schema that omits the key, and
`pack-en` carries 0.68. Every probe scoring in `[0.68, 0.75)` was answered
differently on the two runtimes. Same pack, same utterance, two answers, nothing
red anywhere.

`contestedConfidence = 0.60` is that same shape, in three places at once:

| Runtime | Where | Ownership |
|---|---|---|
| iOS | `PackClassifierAdapter.contestedConfidence` | code constant |
| Android | `OfflineNluServiceImpl.contestedConfidence` (`private val`) | code constant |
| Python | `IntentClassifier.CONTESTED_CONFIDENCE` | class constant |

**The reference already says so.** Its own comment marks the value PROVISIONAL:

> "This is the one constant left in the confidence path, and it is currently a
> placeholder chosen to land inside the confirmation band. It must be fitted
> out-of-fold on `train.csv` (never on the holdout — that is blocker B9) by the
> joint (FIRE, FLOOR) sweep… Shipping a fitted 0.75 in place of a guessed 0.75
> would repeat the original defect with better manners."

So this is named debt with a named fix, not an oversight. It is recorded here
because the ticket did not exist anywhere.

**Why it matters more than it looks.** 0.60's only job is to sit BELOW the fire
threshold, so a contested rule can never fire on its own. Today
`thresholds.confidence` is 0.70 and it does. The moment a language pack ships a
different fire threshold — a better-calibrated head that can afford 0.55, say —
0.60 sits ABOVE it, and **every contested keyword turn fires.** On that language
only, with no code change, and with nothing to fail.

That is VIK-050's failure mode exactly: a code constant that happened to agree
with the content until the content moved.

**Shape of the fix, in order:**

1. **Python first.** Fit the value out-of-fold per the reference's own plan. This
   gates the other two — neither runtime should ship a number Python has not
   fitted, because then three "agreed" constants become three guesses again.
2. **Compiler.** Emit `policies.thresholds.contested`. Backward-compatible:
   `policy_schema` stays 1 (no existing field changes shape), and every runtime's
   decoder ignores unknown keys today, so an older build reads a newer pack
   without noticing.
3. **Runtimes.** Read it as an OPTIONAL, defaulting to the current 0.60 when
   absent — the same read-it-or-keep-today's-behaviour discipline `agreement` now
   uses on iOS. Then re-point the invariant that already exists in
   `KeywordArbitrationTests.testTheContestedConfidenceCannotClearTheFireThreshold`
   so it asserts against the PACK's value rather than the constant: that test is
   what would catch the 0.55 scenario above.

**Ordering.** After VIK-055 has shipped and been measured. Changing the number and
the mechanism in one go makes any accuracy delta unattributable — the same reason
VIK-056 is deferred.

**Cross-platform.** Unlike everything else in this document, this needs all three
runtimes plus the pack compiler. Raise it as ONE cross-team ticket, not three:
three independently "fixed" constants is the state it is already in.

---

## 4. Asymmetries that are correct — do not "fix" these

**Pack delivery and failure strictness are coupled.** iOS has a full OTA pipeline:
staging directory → smoke test that builds a real engine from the *staged* pack
through the same `BundleDataLoader` + `PackEngineFactory` the session uses → atomic
swap → `.rollback_target` + a retention policy holding the previous version. So iOS
can afford to throw on a malformed pack: the previous one survives. Android loads
from app assets (`AssetPackSource`) with no OTA at all, so it *must* degrade in
place. Both strategies are right for their own delivery model. VIK-064 is about
the iOS **seed pack**, which has no previous version to fall back to — not about
making iOS lenient.

**Temperature differs, and should.** Android reads `calibration.temperature`
(0.671457, the ONNX/Python value); iOS reads `temperature_coreml_full` (0.54399),
the value fitted for its own CoreML head. Per-backend correct. The operational
consequence is real, though: **the same utterance carries a different confidence
on the two platforms against the same 0.70 bar** — on
`"who is the prime minister of create reminder"` the model's fallback score is
0.640 on Android and 0.729 on iOS. Cross-platform log comparison must compare
*decisions*, never confidences. Belongs in the runbook, not in code.

**Backend pinning.** iOS pins `.cpuOnly` (ADR-017) because ANE and CPU return
different logits for the same model — non-reproducibility under a confidence
gate. Android pins single-threaded ORT with the arena allocator and memory-pattern
planning disabled, because the model runs one ~1 ms inference per turn and extra
threads only cost scratch buffers. Different platforms, same reasoning applied
correctly to each.

---

## 5. Suggested sequencing

| Wave | Items | Rationale |
|---|---|---|
| **0** | Land the in-flight ND-14 / help-guard work | VIK-055 §14 — it modifies the same five files |
| **1** | ~~VIK-055 (arbitration)~~ | **Done.** Shipped three-way after measurement; see VIK-072 for the debt it leaves |
| **1, parallel** | VIK-063 (decision log) · VIK-061 §6 deriver + §5 spike | Neither touches the NLU decision path; the spike answers a question nobody currently has an answer to |
| **2** | VIK-061 Route A / B / C, or close with the finding recorded | Decided by the spike, not in advance |
| **3** | VIK-062, VIK-065 | Small, independent, each closes a contract. VIK-064 drops out — CI already covers its cheap half |
| **4** | VIK-056 (normalisation) **or** VIK-057 (rule order) — not both | Each needs its own holdout measurement |
| **5** | VIK-070 (contested threshold → pack) | Gated on the Python fit; cross-team, all three runtimes |

Waves 1 and 3 are parallelisable. Wave 4 is not.

Raise §2 with the Android team independently; there is no ordering dependency
between the two directions.

---

## Appendix — source anchors

| What | Where |
|---|---|
| Android biasing derivation | `nlupack/NluBiasingDeriver.kt`; delivered `speech/SpeechManager.kt:743` |
| iOS recognition request (no biasing) | `Core/Recognition/SpeechRecognitionService.swift` |
| Android per-turn decision log | `OfflineNluServiceImpl.kt:101` |
| iOS decision log (help guard only) | `NLU/Engine/NLUEngine.swift:551, 615` |
| Android polarity guard | `nlupack/NluGuards.kt::applyPolarityGuards` |
| iOS polarity decoded, unused | `Pack/Schema/PackSections.swift:305, 315, 330` |
| Android normaliser | `nlupack/NluTextNormalizer.kt` |
| iOS contractions decoded, unused | `Pack/Schema/PackLexicon.swift:32, 39, 55` |
| Android graded validation | `nlupack/NluPackValidator.kt`, `NluPackValidation` |
| iOS load-time validation | `Pack/Loader/BundleDataLoader.swift:296-340, 371-380` |
| iOS OTA staging / smoke test / rollback | `OTA/Installer/NLUPackInstaller.swift`, `OTA/Storage/PackStorageController.swift` |
| Android warmup in init | `OnnxIntentClassifier.kt:68` |
| Android date-time parser | `nlupack/SysDateTimeParser.kt:33` |
| iOS partial-day parking | `NLU/Engine/NLUEngine.swift::resolveDateTime` |
| Android endpointing window | `speech/ByteVad.kt:114` |
| iOS content-aware endpointing | `NLU/Engine/NLUEngine.swift::assessSlotAnswer` |
| The one field iOS deliberately does not model, and says why | `Pack/Schema/PackSections.swift:257-293` |
| VIK-070 — the constant, three times | `PackEngineFactory.swift::PackClassifierAdapter.contestedConfidence`; `OfflineNluServiceImpl.kt:29`; `classifier.py::IntentClassifier.CONTESTED_CONFIDENCE` |
| VIK-070 — the precedent (VIK-050) | `NLUEngine.swift::interruptThreshold` doc comment |
| VIK-070 — the invariant to re-point | `KeywordArbitrationTests.testTheContestedConfidenceCannotClearTheFireThreshold` |
