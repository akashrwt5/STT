# VoiceAIKit — Bug Tracker

Defects found while making the package data-driven. The pack compiler's own
tracker lives in the IntentClassifier repo (`docs/BUG_TRACKER.md`); anything
here is iOS-side, or a contract gap that bites iOS specifically.

**Summary:** 26 fixed, 11 open.

Two of the fixes (VIK-015, VIK-016) were found by the parity suite on its first
run, in code that compiled cleanly and had been read against the reference twice.

Five more (VIK-017, VIK-018, VIK-020, VIK-021, VIK-023) came from reading the
pack's own tables and comparing them to what the Swift actually consults. None
would have failed a build, and none produces an error at runtime: the failure is
always a slot that does not fill, a question re-asked, or an action taken with
the wrong data and reported as success. That is the shape of every remaining
defect in this package, and it is why "it compiled and the demo worked" is not
evidence here.

| ID | Area | Sev | Summary | Status |
|---|---|---|---|---|
| VIK-001 | NLU | **Critical** | `NLULexicon` silently yields English word-lists for any pack | **Fixed** |
| VIK-002 | classifier | **High** | Tokenizer does not match the trainer — features never match | **Fixed** |
| VIK-003 | data layer | **High** | `fuzzy` flag lost in the pack join — approximate matching silently off | **Fixed** |
| VIK-004 | data layer | Med | Fuzzy confidence rounding — every fuzzy match scored 0.90 | **Fixed** |
| VIK-005 | build | Med | Swift type-checker timeout on chained collection expressions | **Fixed** |
| VIK-006 | classifier | Med | `computeUnits = .all` — non-reproducible logits under a confidence gate | **Fixed** |
| VIK-007 | contract | **High** | Fuzzy-matching rules exist only in Python; stopword list is English | Open |
| VIK-008 | contract | **High** | Vectorizer parameters not in the pack | Open |
| VIK-009 | NLU | **High** | `EntityExtractor` is ~890 lines of hardcoded English | **Fixed** |
| VIK-010 | data layer | Med | `head.json` declared by every pack, shipped by none | Open |
| VIK-011 | NLU | Med | Empty-feature utterances can clear the confidence gate | Open |
| VIK-012 | data layer | Low | Grammar lookup tables rebuild on every access | Open |
| VIK-013 | contract | Med | No golden parity fixtures in the pack | Open |
| VIK-014 | contract | Med | Pack has no vocabulary for spoken clock minutes above 31 | Open |
| VIK-015 | NLU | **High** | Ordinal normalisation stripped the day-of-month marker | **Fixed** |
| VIK-016 | NLU | Med | "tonight" resolved to a bare day, losing its time | **Fixed** |
| VIK-017 | contract | **High** | v3 drops the `open` entity flag — free-text slots stop filling | **Fixed** |
| VIK-018 | NLU | **High** | `sys.date-time` vs `sys.date_time` — date slots never matched under a pack | **Fixed** |
| VIK-019 | contract | Med | `dynamic_source` does not say WHICH builtin an entity is | **Fixed** |
| VIK-020 | NLU | **High** | Dynamic entities reported as "open", taking a free-text topic | **Fixed** |
| VIK-021 | NLU | **Critical** | Confirmation gate ignores `policies.confirmation`, skipping all slot collection | **Fixed** |
| VIK-022 | contract | **High** | Pack lexicon is missing the "set a reminder" carrier phrase | **Fixed** |
| VIK-023 | NLU | **High** | `negation_cues` wired into `uncertain` — "cancel" could not cancel | **Fixed** |
| VIK-024 | NLU | **High** | `leading_connectors` shipped by every pack, applied by nothing | **Fixed** |
| VIK-025 | NLU | **High** | Topic stripping mirrored the wrong reference path — 8/20 utterances diverged | **Fixed** |
| VIK-026 | contract | Med | Grammar cannot say which weekday synonyms are safe to strip | Open |
| VIK-027 | testing | Med | Facade turn state-machine (external-TTS handoff) not unit-tested — needs a mockable engine/coordinator seam | Open |
| VIK-028 | STT | **Critical** | Apple `isFinal` at a grammatical boundary treated as end-of-turn — mic cut off mid-sentence, wrong intent on an incomplete phrase | **Fixed** |
| VIK-029 | concurrency | **High** | Result loop in the task-group body could hang (and swallow the error) when `analyzer.start()` fails | **Fixed** |
| VIK-030 | contract | Med | `runtime/routing.json` is decoded and never read — the pack's ladder and `assist_cloud` switch do nothing | Open |
| VIK-031 | security | **High** | Unresolved turns returned a URL built from pack data, with the user's transcript in its query string | **Fixed** |
| VIK-032 | STT | **High** | A locale the device cannot transcribe was swallowed by `try?` — pack in one language, recogniser in another, silently | **Fixed** |
| VIK-033 | packaging | Med | The package persisted the transcription locale in the HOST app's `UserDefaults.standard` | **Fixed** |
| VIK-034 | contract | Med | `bundle.json` has TWO independent Decodable models that read different subsets of it | Open |
| VIK-035 | security | **High** | The host extractor rewrote `bundle.json` before signature verification — every OTA install would fail once signing is on | **Fixed** |
| VIK-036 | NLU | **High** | Keyword-routed intents skipped the confirmation gate — `Cmd.SendMessage` (`always`) sent without asking | **Fixed** |
| VIK-037 | NLU | Med | An open slot's free text was overwritten by a gazetteer canonical — a reminder the user named "drink water" was stored as "Drink Water" | **Fixed** |

---

## Fixed

### VIK-001 — `NLULexicon` silently yields English word-lists for any pack
The worst defect in the package, and it had no symptom.

`NLULexicon` expected `carrier_phrases`, `weekdays`, `months`,
`numbers_0_to_31` at the top level. A pack ships `carriers` and a nested
`datetime_grammar`. **Not one field name overlapped.** Because every field
decoded with `try? … ?? []`, feeding it a real pack produced an ALL-EMPTY
struct — no throw, no log — and `NLUEngineFactoryProvider` then substituted
`NLUEngine.defaultUncertain` / `defaultNoIdioms` / `defaultCarriers`, which are
hardcoded English.

A French pack would have run English rules and passed every test.

**Fix:** `PackLexicon` decodes strictly. A missing required key throws
`VoiceIntentError.malformedJSON`. No field defaults to empty.

### VIK-002 — Tokenizer does not match the trainer
`TFIDFLogisticScorer.tokenize` split on non-alphanumerics and kept every
non-empty token. scikit-learn's default `token_pattern = r"(?u)\b\w\w+\b"`
requires **two** word characters, and filters BEFORE assembling n-grams.

So `"set a reminder"` trains the model on `set reminder`, while the device
produced `set a` + `a reminder` and never generated the trained feature.

Measured on `holdout_honest.csv`, n = 1470, full head:

| | accuracy | passes gate |
|---|---|---|
| trainer tokenisation | 0.9027 | 0.8823 |
| shipped tokenisation | 0.9020 | 0.8735 |

11 label disagreements (0.75%). Accuracy barely moved; **gate-pass lost
0.88pp** — 13 more utterances per 1470 fall under 0.70 and get a reprompt
instead of an action. That is the number a user feels.

**Fix:** `PackTFIDFVectorizer.tokenize` applies the 2-character minimum before
n-gram assembly, and treats `_` as a word character to match Python's `\w`.

### VIK-003 — `fuzzy` flag lost in the pack join
`BundleDataLoader.join` flattened `EntityDefinition` down to
`canonical → synonyms`, discarding `fuzzy`. `PackEntityExtractor` then read a
flag that was always false, so approximate matching was **off for every
entity**.

Failure mode: a user says a memory name with one letter wrong, the slot does not
fill, the assistant re-prompts, and nothing anywhere records why.

**Fix:** `ResolvedPack.fuzzyEntities` carries the flag through the join.

### VIK-004 — Fuzzy confidence rounding
```swift
(1.0 - ratio * 100).rounded() / 100     // wrong
((1.0 - ratio) * 100).rounded() / 100   // right
```
Mirroring `round(1.0 - d/len, 2)`, the ×100 / ÷100 is the 2-decimal rounding and
must wrap the whole subtraction. Applied to the ratio alone it produces values in
the hundreds, which the [0.60, 0.90] clamp flattens — so **every** fuzzy match
reported 0.90 regardless of how bad the spelling was.

Caught before shipping, but only because the value was checked against the
reference rather than eyeballed.

### VIK-005 — Swift type-checker timeout
`PackLexicon.swift:237` — "The compiler is unable to type-check this expression
in reasonable time". Chained `flatMap` → `sorted` → `map` with un-annotated
tuple literals; Swift must solve the element type across all three links at once.

Four more instances had the same shape and would have failed in turn
(`ordinalPhrasesLongestFirst`, `ResolvedPack.slots`, `keywordRulesByTier`,
`NLUBundle.formatMajor`).

**Fix:** explicit loops with declared types; a named `PhraseMatch<Value>` and
`ResolvedSlot` in place of tuples. Also removed a custom `+` overload on
`[String: [String]]` — an inference hazard and surprising to read.

**Recurred** while wiring `leadingConnectors` into `NLUEngine.init`:
`map` → `filter` → `sorted`, with a ternary inside the sort closure, over
`[String]`. Same failure, same line shape, in a file that had never had the
problem. Knowing about this defect is evidently not enough to avoid writing it,
so treat the chained form as banned in this package rather than discouraged.

Two further instances were hoisted pre-emptively: `Set.sorted().joined()` inside
an `os.log` interpolation (`PackContentGaps`, `PackSlotResolver`). `OSLogMessage`
interpolation is its own expensive type-check context, and a collection chain
inside one stacks two of them.

### VIK-006 — `computeUnits = .all`
`IntentClassifierService:142` requested `.all`. ADR-017 measured this exact head:
93.7 ms load vs 15.6 ms, +1.69 MB app footprint, and — the reason it is not
merely a performance question — **ANE and CPU return different logits from the
same model**. Under `.all` the backend is CoreML's choice and varies with device,
thermal state and ANE contention, so the shipped model is not reproducible run to
run. With a 0.70 gate and canary cohorts compared against each other, that is
undebuggable in support triage.

**Fix:** `PackIntentClassifier` pins `.cpuOnly`.

### VIK-015 — Ordinal normalisation stripped the day-of-month marker
`normalizeOrdinals` rewrote a spelled-out ordinal to a bare digit, so
`"the 25th"` became `"the 25"`. The bare-day branch requires an ordinal marker —
a naked digit is a clock hour on that path — so the marker was the only signal
it had, and removing it made **every bare day-of-month silently stop
resolving**: `"the 25th"`, `"the twenty fifth"` and `"the first"` all returned
nil.

Found by the parity suite on its first run. The reference keeps the marker
(`f"{n}{suffix(n)}"`).

**Fix:** emit a trailing dot — the language-neutral ordinal marker, which German
writes natively ("25.") — and accept `(?:st|nd|rd|th|\.)` in the date patterns.

### VIK-016 — "tonight" resolved to a bare day, losing its time
Packs list `tonight` under `day_anchors` only; `time_of_day` carries
evening/night/noon and no "tonight". The parser read period names from
`time_of_day` alone, so `"tonight"` matched the day anchor, found no period, and
fell through to the 09:00 default — **nine hours off**, with no error.

The reference bridges it explicitly, mapping the `tonight` anchor's phrases onto
the `evening` role.

**Fix:** same bridge at init. The mapping is role→role, so no vocabulary is
hardcoded — the words still come from the pack.

### VIK-009 — `EntityExtractor` is ~890 lines of hardcoded English
Literal weekday tables at `:238`, `tomorrow`/`tonight`/`noon` at `:306–343`,
a `timePatterns` regex array at `:766`. The pack carried the full grammar
(`weekdays`, `months`, `numbers_0_to_31`, `ordinals_1_to_31`,
`clock_hour_markers`, `grammar`, `ordinal_context`); the code did not read it.

It could not simply be swapped out, because it was a *concrete* dependency of
`NLUEngine` whose initialiser reads a URL and falls back to `Bundle.module`.
Any pack-driven replacement had a different shape, so the engine had to stop
depending on the type before it could stop depending on the file.

**Fix:** `NLUEngine` now depends on `SlotResolving` — five methods, no file.
`PackSlotResolver` answers them from a `ResolvedPack` via `PackEntityExtractor`
(gazetteers) and `PackDateTimeParser` (dates, and now topic stripping, which
was the last piece still living in the old type). `EntityExtractor` conforms to
the same protocol via a temporary adapter so the non-pack construction sites
keep working until `VoiceIntentSession` takes a pack URL; it is deleted then,
along with the adapter.

The engine's dialog logic is untouched. Only the six call sites moved.

### VIK-018 — `sys.date-time` vs `sys.date_time`
`NLUEngine` decided whether a slot was a date by comparing
`slot.entity == "sys.date-time"`, with a HYPHEN. That is the flattened root
shim's spelling, and the shim is the surface this refactor deliberately does not
bind to. The v3 entity table spells it `sys.date_time`, with an underscore.

So the moment a pack drove the engine, the comparison was always false. Every
date-time slot fell through to the gazetteer path, which has no table for a
dynamic entity and therefore never resolved. `reminders.task.create` would ask
for a time, receive one, fail to fill the slot, ask twice more and drop the user
to fallback — with a green build and no log line.

Found by diffing the pack's actual slot entities against the literal, not by
running anything.

**Fix:** the engine asks `entities.isDateTime(_:)` instead of comparing. Each
implementation knows its own surface's spelling: the pack resolver reads
`pack.dynamicEntities`, the legacy adapter keeps the hyphen.

### VIK-020 — Dynamic entities reported as "open"
`PackEntityExtractor.isOpen` returned `tables[entity]?.isEmpty ?? true`. Its own
doc comment said "anything not in a table **and not dynamic**" — the code
implemented only the first half.

A dynamic entity has no table by definition, so `sys.date_time` reported as
open. `NLUEngine.fillOpenTopics` fills every unfilled required open slot with
the free-text topic derived from the utterance, so "remind me to buy milk"
wrote `"buy milk"` into the date-time slot. The slot was then *satisfied*, the
engine stopped asking for a time, and the reminder was created with a
non-date where its date should be. Worse than not filling: it completes.

**Fix:** `isOpen` excludes dynamic entities first, before any table lookup.

### VIK-023 — `negation_cues` wired into `uncertain`
`PackEngineFactory` passed `lexicon.negationCues` as the engine's `uncertain`
list. They are different tables. `uncertain` means *the user answered neither
yes nor no* — the English list was `["not sure", "maybe", "dunno", …]`.
`negation_cues` are words that NEGATE.

`yesNo` tests the uncertain list with `contains` — substring, not whole word —
and returns nil on a hit, which re-asks the same question. Seven of the twelve
words in the pack's own `negative` list contain a negation cue as a substring:

| said | contains cue | result |
|---|---|---|
| cancel | `cancel` | re-asks |
| stop | `stop` | re-asks |
| don't / dont / do not | `don't` / `dont` / `do not` | re-asks |
| never mind / nevermind | `never` | re-asks |

So the words a user reaches for to abandon a confirmation were exactly the ones
that could not. Only "no", "nah", "negative", "nope" and "no thanks" worked, and
there is no escape from the loop except finding one of those five.

**Fix:** pass `[]`. The pack carries no uncertainty table, and empty is the
honest value. "I don't know" now reads as a decline rather than a re-prompt,
which fails safe; the alternative failed by trapping the user.

`ConfirmationAndSlotFlowTests` walks every word in the pack's `affirmative` and
`negative` lists through a live confirmation, so a future mis-wiring fails
loudly instead of quietly.

### VIK-021 — Confirmation gate ignores the pack's policy (**Critical**)
`PackEngineFactory.schema(from:)` builds a `FollowupDef` for any intent whose
workflow carries a `confirmation` block. It reads neither
`confirmation.required` (which it decodes and discards) nor
`policies.confirmation`, which is the table that actually decides:

```
never           43 intents
when_ambiguous  14 intents   ← includes reminders.task.create
always           0 intents
```

`when_ambiguous` means *confirm only when confidence lands in the
`uncertain_confirm` band* (0.55–0.91). Instead every one of the 14 confirms
unconditionally.

That alone would be over-confirming, which is annoying but safe. The damage is
what it does to slots: `NLUEngine.handleNewIntent` checks `cfg.followup`
**before** `cfg.slots`, and returns `.confirm` immediately. So for a gated
intent, slot collection never runs at all — and `handleConfirmation` on "yes"
fulfils with `parameters: [:]`.

"Set a reminder to go to the airport" therefore asks "shall I create that?",
takes "yes", and creates a **completely empty reminder** — no name, no time,
never having asked for either. It reports success.

The English path never hit this: `nlu_schema.json` only ever carried `followup`
on intents that had no slots (`Cmd.SendMessage`), so "confirm instead of
collect" was never wrong there. The pack has both on the same intent, twice.

**Fix, in two parts:**

1. **Which intents gate, and when** — `ConfirmationGate` (`always` / `never` /
   `whenAmbiguous(floor:ceiling:)`), built by
   `PackEngineFactory.confirmationGates(from:)` out of `policies.confirmation`
   and `policies.thresholds`. `NLUEngine` arms a followup only when the gate
   fires for that turn's confidence. An intent with no gate defaults to
   `.always`, which is the pre-pack behaviour, so the legacy path is byte-for-byte
   unchanged.

   The engine's own confidence threshold (0.70) already routes anything below it
   to fallback, so the effective band is 0.70–0.91 rather than the pack's stated
   0.55–0.91. The floor is stored as the pack states it; the two thresholds move
   independently.

2. **Confirmation no longer replaces collection** — when a confirmation is
   armed, the slots the opening utterance already answers are extracted and
   staged first. "Yes" then hands off to `advanceSlots`, which asks for whatever
   is still missing; "no" clears the staged state so an unrelated next utterance
   cannot resume a cancelled flow. A no-slot intent still fulfils directly, so
   `Cmd.SendMessage`-shaped intents are untouched.

   `advanceSlots` finishes with `cfg.action` / `cfg.fulfillment`, which
   `PackEngineFactory` builds from the same `workflow.completion` as
   `followup.yes` — so both paths end identically.

`ConfirmationAndSlotFlowTests` covers the confident path, the ambiguous path
through to fulfilment, declining, and the gate boundaries.

### VIK-024 — `leading_connectors` shipped by every pack, applied by nothing
The reference derives an open-slot topic in THREE steps
(`engine.py::_derive_topic`): strip carriers, strip the date/time, then strip a
leading connector. Swift did the first two.

So the connective that introduced the removed time stayed at the front of the
topic. "Remind me at 9pm for dinner" produced the reminder name "for dinner";
"set a reminder for 5pm" produced the name **"for"**.

**Fix:** `NLUEngine` takes `leadingConnectors`, supplied by `PackEngineFactory`
from `lexicon.leading_connectors`. Anchored as `^(?:…)(?:\s+|$)` — `\s+` alone
cannot match a connector that is the ENTIRE remainder, which is precisely the
"for" case. The same `$` fix was made in the Python engine, where the bug also
existed.

Empty by default, so the pre-pack path is unchanged.

### VIK-025 — Topic stripping mirrored the wrong reference path
`EntityExtractor.strip_datetime` has two implementations and picks by file
presence: `_strip_datetime_lex` for a language with a lexicon file, and
`_en_strip_patterns` for English. They differ in pattern SET **and** pattern
ORDER.

`PackDateTimeParser.strippingDateTime` was written against the lexicon path.
English packs take the other one, and measured against the reference **8 of 20
ordinary utterances diverged**:

| utterance | reference | ours |
|---|---|---|
| dinner at 7 | `dinner` | `dinner 7` |
| call mom on mondays | `call mom` | `call mom mondays` |
| buy milk in the morning | `buy milk` | `buy milk the` |
| take pills at midnight | `take pills midnight` | `take pills` |
| pay rent next week | `pay rent week` | `pay rent` |

Three tables had been dismissed as unused while writing the first version, and
all three are load-bearing in the English path:

- `strip.at_by` removes "at"/"by" **together with the digit** — without it the
  connector goes and an orphan number stays.
- `strip.the` is applied ONLY inside the optional "in the &lt;period&gt;" prefix,
  never standalone. That is why "drink the green tea" keeps its article.
- weekday matching carries an optional plural `s`.

Two further details are deliberate quirks of the reference, reproduced rather
than corrected: `midnight` is excluded from the period alternation, and
recurrence runs AFTER weekdays, so "each saturday" loses its day and leaves a
bare "each".

**Fix:** `strippingDateTime` mirrors `_en_strip_patterns` pattern-for-pattern,
in order, entirely from pack tables. Verified 28/28 against the reference,
including negative cases ("buy sun cream", "sat with mom").

`TopicDerivationParityTests` runs generated fixtures so this cannot recur
silently — which is the actual lesson. The first version was read against the
reference twice and reviewed; nothing but running both found it.

### VIK-028 — Apple `isFinal` treated as end-of-turn (**Critical**)
`SpeechTranscriber` (`.progressiveTranscription`) emits `isFinal = true` at each
grammatical/pause boundary and then starts a fresh chunk — it marks a stable
SEGMENT, not the end of the user's turn. `SpeechRecognitionService` forwarded any
`isFinal` straight to the NLU and flagged the session complete, so a multi-clause
sentence was cut mid-way: "It's a bit louder here, can you reduce the volume"
endpointed after "…louder here", classified that incomplete phrase, and fired the
wrong intent (`Cmd.VolumeIncrease`, on the word "louder"). No VAD/silence log ever
appeared, because Apple's grammar boundary preempted our own 1s timer.

**Fix:** on the live single-utterance path, `isFinal` no longer ends the turn.
Every result (volatile or final) is accumulated into a running transcript
(`finalizedTranscript` + the current volatile chunk — always the WHOLE utterance,
never just the last segment) and surfaced as a partial; the turn commits only via
our own endpointer (transcript-stability + acoustic VAD + max-utterance cap).
Trailing partials arriving after the commit are dropped by a drain guard so the
NLU can't be re-triggered. The file / continuous-captioning path keeps `isFinal`
authoritative (there is no "turn" there). The decision math lives in the pure
`EndpointDecider`; covered by `EndpointDeciderTests` + `SilenceDetectorTests`.

### VIK-029 — Result loop could hang and swallow the analyzer error (**High**)
The session task ran the feed loop and `analyzer.start()` / `finalize…` as
task-group children but iterated `transcriber.results` in the GROUP BODY. If
`analyzer.start()` threw, the body stayed blocked on a results stream that would
never close (a failed analyzer never finalizes), so the child's error was never
observed and `stopTranscribing`'s `await analysisTask.value` hung the teardown —
freezing the main thread.

**Fix:** result iteration moved into a third `@MainActor` task-group child (so
delegate delivery stays synchronous, identical to before), and the group body now
`for try await _ in group { }` — observing every child. The first child to throw
rethrows there, the group cancels the siblings, and the error propagates to the
outer `catch → didFailWith` instead of hanging. `group.cancelAll()` removed (the
observation loop supersedes it). Not yet covered by an automated failure-injection
test (needs a mockable analyzer — see the seam note in VIK-027).

---

## Open

### VIK-007 — Fuzzy-matching rules exist only in Python (**High**, partially resolved)
The pack declares `"fuzzy": true` on an entity and nothing else. The distance
metric (Levenshtein), the 0.3 edit ratio, the 5-character minimum length, and the
confidence tiers (1.00 / 0.95 / 0.60–0.90) still live only in
`packages/runtime/nlu_engine/entities.py::extract_enum`, and `PackEntityExtractor`
mirrors them by hand — an unversioned contract for those four.

**RESOLVED for the two word-list halves (`stopwords` + trailing function words).**
The pack lexicon now carries both — `pack-en-v1.0.36` ships `lexicons/en.json` with
`fuzzyStopwords` (42 words) and `trailingFunctionWords` (30 words), and `PackLexicon`
decodes both. `PackEngineFactory.makeEngine` now sources them from the lexicon
(`stopwords ?? lexicon.fuzzyStopwords`, `trailingFunctionWords ?? lexicon.trailingFunctionWords`),
with the host `VoiceIntentConfiguration` fields as an optional override. So a
non-English pack ships its own `le`/`la`/`de` (and its own mid-thought words) with no
code change, and there is no hardcoded English fallback — the earlier silent-English
risk (VIK-001 class) is gone for these. The stopword list was what stopped `the`
fuzzy-matching the memory `three`; it is now data-driven.

Still open: the metric / ratio / min-length / confidence tiers remain hand-mirrored
Python constants. If the reference changes one, nothing in the pack says so.

**Ask:** carry the remaining `fuzzy: {algorithm, max_distance_ratio, min_length}`
per entity (or per language) so the last four leave the code too.

### VIK-008 — Vectorizer parameters not in the pack (**High**)
iOS rebuilds scikit-learn's TF-IDF in Swift. `ngram_range=(1,2)`, `min_df=2`,
`sublinear_tf`, `lowercase`, `norm="l2"` and the token pattern are reproduced
from the trainer and appear nowhere in the pack — the repo's `calibration.json`
has them as a prose string, and the pack's copy strips even that.

VIK-002 is what this gap looks like when it goes wrong: a silent accuracy and
gate-pass loss that no test catches. It will happen again on the next trainer
change.

**Ask:** emit the fitted vectorizer configuration machine-readably beside the
weights.

### VIK-010 — `head.json` declared by every pack, shipped by none (Med)
`bundle.json` declares `models/semantic_head/shared/head.json`; only the
`.mlpackage` ships. Tolerated by an explicit entry in
`PackLoadPolicy.toleratedMissingArtifacts` — refusing every current pack over a
field nothing reads would be pedantry, but the tolerance is a workaround for a
compiler defect (IntentClassifier BUG-013) and should be removed when that is
fixed.

### VIK-011 — Empty-feature utterances can clear the gate (Med)
When no token matches the vocabulary the feature vector is all zeros, every
logit collapses to its intercept, argmax becomes a fixed label, and softmax over
those returns a confidence that **can exceed 0.70**. Measured at 5 of 1470
holdout rows (0.34%).

`PackIntentClassifier` surfaces this as `Prediction.isVacuous` and forces
`passesGate = false`, but the pack does not define what should happen — routing
to `sys.oos.fallback` is currently the caller's decision.

**Ask:** state the empty-feature contract in the pack.

### VIK-012 — Grammar lookup tables rebuild on every access (Low)
`weekdayIndex`, `monthIndex`, `numberIndex`, `ordinalPhrasesLongestFirst` and
`dayAnchorPhrasesLongestFirst` are computed properties on `DateTimeGrammar`, so
each access rebuilds the whole table. Fine at setup, wrong per-utterance.
`PackDateTimeParser` must build them once at init and hold them.

### VIK-013 — No golden parity fixtures in the pack (Med)
The pack contains no fixture set, so nothing proves the Swift runtime reproduces
the Python reference. VIK-002 and VIK-004 were both found by hand-running the
reference; neither would have been caught by a test.

~200 utterances with expected label and confidence to 4dp, emitted by the
model's own build, would turn every item in VIK-007/008 from a silent field
failure into a failed assertion at integration time. ~20 KB against a 8.9 MB
pack.

Partially mitigated: `Tests/.../Fixtures/reference_expectations.json` is captured
by running the reference locally. That is a stopgap — the fixtures are generated
by hand on a developer machine rather than published by the model's build, so
nothing guarantees they match the pack a device actually receives.

### VIK-014 — No vocabulary for spoken clock minutes above 31 (Med)
`datetime_grammar.numbers_0_to_31` is sized for days of the month and stops at
31, so no pack carries "forty" or "fifty". A spoken clock time like
**"four fifty"** therefore cannot resolve on device.

The reference gets it right (16:50) through a hardcoded `_WORD_NUMS` table that
includes 40/50/60 specifically for clock minutes — the one table deliberately
NOT moved into the pack, because a 0–31 range cannot express it.

So this is a genuine, measurable divergence between the two runtimes on ordinary
input. Asserted in `PackDateTimeParityTests` as a known gap and listed in
`knownContractGaps`, so the suite stays green and the divergence stays visible;
the assertion flips to a failure the moment a pack gains the vocabulary.

**Ask:** add a `clock_minutes` table (or extend the numbers table to 0–59 and
rename it) to `datetime_grammar`.

### VIK-017 — v3 drops the `open` entity flag (**High**)

**CLOSED end to end.** The compiler emits `open`; `EntityDefinition` decodes it;
`BundleDataLoader` carries it across the flatten into `ResolvedPack.openEntities`
— that second step matters, because a flag the join drops is a flag that does not
exist, which is what VIK-003 was. `PackContentGaps` and the host override are
deleted. Carried by `pack-en-v1.0.30` onward; a pre-fix pack now logs a notice
rather than failing quietly.
**RESOLVED in the compiler.** `spec/bundle/3.0/entities.schema.json` gains an
`open` boolean; `content_bundle.compile_entities` emits it alongside `fuzzy`.
The flag was present in `language_packs/en/nlu_entities.json` all along and was
dropped by the projection, with the schema's `additionalProperties: false`
making it unexpressible even if emitted. Verified: emitted entities validate,
`remind.open == true`, unknown keys still rejected.

The iOS `PackContentGaps.openEntities` override stays until a pack built from
the fixed compiler ships — this session could not re-sign one (`pynacl` and the
dev key are not available here). `PackSlotResolverTests` fails when the new pack
arrives, which is the cue to delete it.

`entities/shared/content.json` carries `type` and `fuzzy` per entity. The
flattened root shim carries a third: `"remind": {"open": true}`. Nothing in the
v3 surface does.

`open` means the value list is a hint, not a closed set, so a free-text answer
is acceptable. It drives two things in `NLUEngine`: accepting the raw utterance
when structured extraction returns nil, and `fillOpenTopics`, which derives a
topic from the first utterance so a reminder can be created in one turn.

Without it, `pack-en`'s `remind` entity looks closed and the only reminders that
can be created are the six canned ones in the gazetteer. "Remind me to call the
plumber" cannot fill its own name slot. This is a behaviour regression the
moment the pack path goes live, and it is invisible — the slot just re-prompts.

Currently a parameter on `PackSlotResolver.init` / `PackEngineFactory.makeEngine`
(`openEntities:`), defaulting to empty, so nothing is guessed. Asserted in
`PackSlotResolverTests` so the gap stays visible rather than becoming folklore.

**Ask:** carry `open` through to `entities/*/content.json` alongside `fuzzy`.
It already exists upstream — it is dropped in the v3 projection, not absent from
the source.

### VIK-019 — `dynamic_source` does not say which builtin (Med)

**CLOSED end to end.** `PackSlotResolver` now dispatches on the pack's declared
`dynamic_source`, not on how an entity id is spelled. Id matching survives only as
a scoped fallback for pre-fix packs, which log a notice saying so.
**RESOLVED in the compiler.** `compile_entities` now emits
`runtime.builtin.datetime` / `runtime.builtin.integer` from a table keyed by
entity name, and warns when a builtin has no mapping. No schema change was
needed — `stableId` already permits dotted segments.

iOS still dispatches on the entity id (`PackSlotResolver.dateTimeEntityIDs`)
because `BundleDataLoader` discards `dynamic_source` during the join. Switching
to the qualified source is a follow-up, and pointless until a pack carries it.

Both dynamic entities declare the same thing:

```json
"sys.date_time":      {"type": "dynamic", "dynamic_source": "runtime.builtin"},
"sys.number_integer": {"type": "dynamic", "dynamic_source": "runtime.builtin"}
```

`runtime.builtin` says the runtime resolves it, not WHAT it resolves. A runtime
that must route one to a date parser and the other to a number parser can only
tell them apart by their ids — so the id carries meaning the format says it does
not, and a pack that renamed either would break the device silently.

`PackSlotResolver.dateTimeEntityIDs` is that coupling, isolated to one constant
and logged at load when a slot names a builtin this runtime cannot resolve.

**Ask:** make `dynamic_source` name the builtin — `runtime.builtin.datetime`,
`runtime.builtin.integer` — so the id is free to change and an unknown builtin
is detectable rather than merely unresolvable.

### VIK-022 — Pack lexicon is missing the "set a reminder" carrier (**High**)

**CLOSED end to end.** The portable carrier ships in `pack-en-v1.0.30`;
`additionalCarriers` and `PackContentGaps` are deleted. The test now asserts the
carrier is present AND that no carrier contains a lookahead — the property, not
the one string.
**RESOLVED — and the original diagnosis here was wrong.** The carrier was not
forgotten. `language_packs/en/platform.yaml` has all six. `compile_lexicon`
runs every carrier through `portable_regex.check_pattern`, and this one contains
`for\s+(?!\d)` — negative lookahead, explicitly forbidden by the portable
subset. It was therefore dropped into a `gaps` log line on every build ever
made, while the Python engine's `_DEFAULT_CARRIERS` kept it. The two runtimes
have been disagreeing on ordinary input the whole time; iOS just noticed first.

**Fix:** the `for` branch is removed rather than the guard rewritten. A leading
"for" left behind is handled by `leading_connectors` one step later (VIK-024),
so the branch was redundant. Verified identical on 10/11 reminder utterances and
strictly better on the other two — "set a reminder for 5pm" produced a reminder
named "for" before. Changed in `platform.yaml`, `nlu_schema.json` and
`engine.py` together, so the content and the reference cannot drift again.

**And the guard that hid it:** a non-portable carrier is now a BUILD FAILURE,
not a coverage-gap line. A carrier changes what the runtime extracts; it is not
metadata, and demoting it to a log entry is what let this survive.

`lexicons/en.json → carriers` ships five anchored patterns. The app's
`NLUEngine.defaultCarriers` has six. The one the pack does not have:

```
^\s*set(?:\s+up)?\s+(?:an?\s+)?(?:reminder|alarm)\b\s*(?:to|about|for\s+(?!\d))?\s*
```

Carriers are stripped to expose a free-text topic. With this one absent:

| said | topic derived |
|---|---|
| "remind me to go to the airport" | `go to the airport` ✅ |
| "set a reminder to go to the airport" | `set a reminder to go to the airport` ❌ |

The second stores the entire utterance as the reminder's name. Not a crash, not
a re-prompt — a reminder that reads back wrong.

It is not a new phrasing anyone overlooked. It exists in this repo's history
(`6572a90 fix: extend set-reminder carrier to also strip 'set an alarm'`), which
means the app-side fix was never carried upstream into the compiler's lexicon.
Whatever else the fr/de/da lexicons are missing has the same shape and will not
be visible until someone speaks the language.

Currently supplied by the host via `PackContentGaps.additionalCarriers`, logged
as an error on every engine construction, and asserted in
`ConfirmationAndSlotFlowTests.testMissingCarrierIsStillMissingFromThePack` —
which starts failing when the pack gains it, as the prompt to delete the
override.

**Ask:** add the carrier, and diff the app's historical carrier fixes against
each language's lexicon rather than only this one.

### VIK-026 — Grammar cannot say which synonyms are safe to strip (Med)
Topic stripping removes weekday names from free text. A pack carries both
"monday" and "mon", "saturday" and "sat", "sunday" and "sun" — and stripping the
abbreviations wrecks ordinary topics: "buy sun cream" becomes "buy cream", "sat
with mom" becomes "with mom".

The reference sidesteps this with a hardcoded list of full English names.
`datetime_grammar` has no field marking a synonym as safe to remove from free
text, so `PackDateTimeParser` uses length (`weekdayStripMinimumLength = 4`) as a
stand-in. For English that reproduces the reference exactly; for a language whose
ordinary vocabulary collides differently, it is a guess.

Same shape as VIK-007: a rule that exists only as a Python constant.

**Ask:** mark synonyms that may be stripped from free text — e.g.
`"Monday": {"synonyms": ["monday","mon"], "strippable": ["monday"]}` — or carry
the strip list separately.

Related, and deliberately not worked around: `_en_strip_patterns` has no
continental clock forms (`15h30`, `15.30`), which the lexicon path does have.
Adding them now would strip "5.50" out of an English topic to serve a 24-hour
pack that does not exist yet.

### VIK-027 — Facade turn state-machine is not unit-tested (Med)

The endpointing DECISION math was lifted into `EndpointDecider` (pure, clock-free)
and is covered by `EndpointDeciderTests`. What remains uncovered is the
`VoiceIntentSession` turn state-machine — specifically the external-TTS handoff
sequencing: a prompt emits, the session holds in `.speaking`, and only
`hostDidFinishSpeaking()` (or the 30s watchdog) advances it to resume listening. The
turn-advance branching (`awaitingAnswer` → listen, `autoStopOnSilence` → idle vs
continuous) and the invariant that the mic never reopens before the host has finished
speaking (no self-capture, no premature reopen) are likewise unverified.

They cannot be unit-tested as written. `VoiceIntentSession` constructs a concrete
`TranscriptionCoordinator` internally and drives a real `ConversationEngine`, so a
test cannot advance a turn without a live recognizer, a pack, and a microphone. The
same is true of the app-provided-audio lifecycle (`.listening` gating of
`provideAudio`, drop-between-turns) beyond the provider-level unit tests already in
`AppAudioInputProviderTests`.

**Needs:** a mockable seam — a protocol for the coordinator (start/stop live
transcription, silence config, delegate callbacks) and injection of the
`ConversationEngine` — so a test can push a synthetic final result, assert the emitted
`.turn` event and the `.speaking` hold, call `hostDidFinishSpeaking()`, and assert
listening resumes; and assert the watchdog auto-advances after the timeout. This is a
facade refactor with real regression surface, deliberately NOT done alongside the
endpoint-math extraction so the working facade stays untouched.

**Related debt (not this ticket):** the two `SpeechRecognitionService` copies —
`VoiceAIKit/Sources/.../Core/Recognition/` and the app's `STT/STT/Recognition/` —
have diverged. The endpointing / `isFinal` / app-audio fixes landed only in the
package copy; the app copy still carries the old behaviour. Consolidating to the
single package source (per MIGRATION.md Phase 2) removes the drift and the risk of a
fix being made in one and not the other.

### VIK-031 — Unresolved turns handed back a pack-supplied URL (**High**) — Fixed

`NLUEngine` answered every unresolved turn with
`.fallback(url: await classifier.genaiURL(for: text), …)`. That URL was built by
`PackClassifierAdapter` from `genai_base_url` in the classifier weights blob, with
the user's **verbatim transcript** appended as `?q=`.

Three things were wrong with it at once:

1. **Security.** The base URL is pack data. Until pack signatures are enforced
   (see `TODO.md`), an attacker-authored pack chooses where transcripts are sent —
   the only path in the package that reaches the network at all, in an SDK whose
   selling point is that it does not.
2. **Nobody used it.** `PackageVoiceView` discarded it with `_`; the app's own
   view model rendered a card and never opened it; the tests stubbed
   `example.invalid`. The shipping en pack's value is the placeholder
   `https://genai.yourcompany.com/chat?query=` — a domain that does not resolve —
   and `genaiURL` overwrote the query string anyway, so even that was discarded.
3. **Wrong layer.** `SPEC-voice-understanding-provider.md` is explicit: the host
   runs its own fallback chain, and a provider "MUST NOT attempt any fallback
   themselves". A URL is the engine answering a question that is not its own.

**Fix:** the URL leaves and the intent name takes its place —
`NLUResponse.fallback(intent:confidence:breakdown:)`, surfaced as
`VoiceIntentTurn.notUnderstood(intent:confidence:stages:)`. The name is the pack's
own out-of-scope label (`ResolvedPack.outOfScopeIntent`), which is
`Default Fallback Intent` for every pack shipping today — the same name the host's
intent table already dispatches from its Dialogflow days, so an unrecognised
utterance needs no special-casing on the host side at all. `genaiURL` is gone from
`IntentClassifying` and `genai_base_url` is no longer read.

`outOfScopeIntent` had to be widened to match it. It looked only for
`*.oos.fallback` / `sys.oos.fallback`, which is nil for every current pack — so
`PackClassifierAdapter` was substituting `""` on the vacuous-prediction path
(VIK-011), and an empty label matched nothing downstream.

Follow-on for the compiler team: drop `genai_base_url` from the weights blob, and
replace the `Default Fallback Intent.done` response — it currently reads "Done.",
which is what a hearing aid would say aloud to a user it did not understand.

### VIK-030 — `runtime/routing.json` is decoded and never read (Med)

Every pack ships it, `BundleDataLoader` decodes it, `ResolvedPack.routing` holds it,
and no code path consults it. The en pack says:

```json
{"assist_cloud":{"enabled":false},
 "ladder":[{"step":"reprompt","when":{"below_confidence":0.7}},
           {"step":"give_up","when":{"after_attempts":3}}]}
```

So the pack disables cloud assist while the engine was building a cloud URL (VIK-031),
and declares a two-step ladder that the engine approximates with a hardcoded
`slotAttempts >= 3` and no reprompt step at all. Same shape as VIK-024: a table
shipped by every pack and applied by nothing, which means the pack cannot change the
behaviour it appears to control.

**Ask:** wire the ladder — `below_confidence` → reprompt (bounded by
`budget_per_session`), `after_attempts` → give up — and honour `assist_cloud.enabled`
as the gate on whether a below-gate turn is offered to the host as a hand-off
candidate at all. Today all three routes (out of scope, below gate, three failed slot
attempts) collapse into one `.fallback(intent:)`, so a host that wants the ladder has
to rebuild it from confidence alone.

### VIK-032 — An unsupported locale was swallowed, not surfaced (**High**) — Fixed

`VoiceIntentSession.prepare()` called

```swift
try? await coordinator.switchLocale(to: config.language.localeIdentifier)
```

`switchLocale` throws `TranscriptionError.localeNotSupported` when
`SpeechTranscriber.supportedLocale(equivalentTo:)` has no model for the requested
locale — a Danish session on a device with no Danish speech model, say. `try?`
dropped that on the floor, and the recogniser carried on with the locale it had been
CONSTRUCTED with, which came from the persisted override or the hardcoded `en-IN`.

The result is the failure this package is otherwise careful to make impossible: the
NLU bound to a verified Danish pack, the recogniser listening in English, no error
thrown, no `.error` event, and a confident wrong intent at the end of the turn.
`buildEngine()` refuses to substitute a language; this line did it anyway, one step
later, on the other half of the pipeline.

**Fix:** `try`, not `try?`. `start()` already wraps `prepare()` in a `do/catch` that
sets `.stopped`, yields `.error` and rethrows, so the host now learns that the
language it asked for is not one this device can hear.

### VIK-033 — The package persisted the locale in the host's `UserDefaults` (Med) — Fixed

`TranscriptionCoordinator` read and wrote `UserDefaults.standard` under
`stt.userSelectedLocale` in eight places, and `SpeechRecognitionService.performPrewarm`
read the same key directly to decide which model to warm. An un-namespaced key in a
host application's shared defaults, written by an SDK the host did not ask to store
anything.

It arrived by copy. In the app this code came from, a real language-picker screen
(`LanguageSelectorView`) legitimately wanted the user's choice to survive a relaunch;
`MIGRATION.md` Phase 1 copied the coordinator across verbatim and the persistence came
with it. What is a feature in an app is global mutable state in a package.

Ordering was, to be fair, correct on the happy path: the write happened before the
prewarm re-arm, so the prewarm read back the value just written. The damage was on the
failure path (VIK-032), where the rolled-back stale value became the locale the
recogniser actually ran in.

**Fix:** the locale is a constructor parameter with no default —
`TranscriptionCoordinator(locale:)` / `(appAudioProvider:locale:)`, passed from
`VoiceIntentConfiguration.language` at session construction. Prewarm warms the locale
the service already holds. Nothing is persisted, and the hardcoded `en-IN` is gone.

`resolveCurrentLocaleIfNeeded` changed shape too, and this part is a behaviour fix
rather than a move: it used to run the auto-detect chain (override → device locale →
device language → en-IN), whose later steps substitute a DIFFERENT LANGUAGE. It now
canonicalises the configured locale against `SpeechTranscriber`'s supported set and
leaves an unsupported one alone, so it fails loudly through VIK-032's path instead of
quietly becoming English.

Downstream: with `UserDefaults` gone the target uses no required-reason API, so the
`PrivacyInfo.xcprivacy` added for CA92.1 was removed, and with it the only `resources:`
entry — restoring the structural zero-data guarantee (no resource means SwiftPM does
not synthesise `Bundle.module` at all).

### VIK-034 — Two Decodable models of `bundle.json`, each missing what the other reads (Med)

`NLUBundle` (`Data/`, the session load path) and `NLUPackManifest` (`OTA/Models/`, the
installer and `VoiceIntentClient`) both decode `bundle.json`, independently, and
disagree about what is in it:

| field | `NLUBundle` | `NLUPackManifest` |
|---|---|---|
| `bundle_id` | yes | yes |
| `version` | **was absent** — added for `PackIdentity` | yes, required |
| `channel` | yes | **absent** |
| `compiler_version` | yes | **absent** |
| `checksums_root` / `signature_info` / `created_at` | yes | yes |

Two live consequences. The session path could not report a pack version at all until
`version` was added to `NLUBundle` — which is why `activePackVersion()` had to re-read
the file from disk and answer a subtly different question than "what is loaded?". And
the OTA path cannot see `channel`, so `refusesDevelopmentPacks` is enforced only inside
`BundleDataLoader`: the installer stages and activates a pack without ever asking which
channel signed it, and the refusal lands later, when a session tries to load it.

There is no reason for two models. One type, decoded once from the verified bytes,
handed to whoever needs it.

**Also:** `version` is optional in one and required in the other, for the same file.
Confirm with the compiler team whether it is guaranteed; if it is, tighten `NLUBundle`
and drop the optionality out of `PackIdentity`.

### VIK-035 — The host extractor rewrote `bundle.json` before it was verified (**High**) — Fixed

`STTPackExtractor.extract` — the host's `PackExtractor`, called by
`PackValidator.extractAndValidate` as **step 1** — injected a `version` field into
`bundle.json` when the compiler had not emitted one, parsing it out of `bundle_id`, and
wrote the patched JSON back to disk.

`PackValidator` then ran `PackIntegrity.verify` as **step 3**. The Ed25519 signature
covers `integrity/manifest.sha256 ‖ bundle.json`, and `bundle.json` is deliberately
excluded from the checksum table — the signature is the only thing binding it. So the
bytes being verified were bytes the host had just edited.

Nothing caught it, and nothing would have until production. The dev trust policy sets
`skipsSignatureVerification: true`, so that step never ran. The day ADR-005 Part 11's
production policy is switched on, every OTA install fails with `integrityCheckFailed` —
and the message reads as *"this pack was tampered with"*, which is true, by us.

**Fix:** the injection is gone, with a comment at the site saying nothing below that line
may write into a pack. Hoisting a single top-level directory stays: it moves files, it
does not edit them, and it produces the pack root the manifest's relative paths assume.

**Why the field can be required now:** `nlu_compiler` commit `bd3c5bf` emits `version`
from the same variable that builds `bundle_id`, before `build.py` signs. So
`NLUBundle.version` and `PackIdentity.version` are non-optional, and a pack built before
that commit is refused at decode instead of being silently repaired.

**Still to do:** the vendored seed pack was built 2026-08-08, four days before `bd3c5bf`,
and only loads today because a `version` was hand-added to it for OTA testing. Rebuild
and re-vendor it from the fixed compiler.

### VIK-036 — The keyword path skipped the confirmation gate (**High**) — Fixed

VIK-021 again, on the other road into the engine. `handleNewIntent`'s Stage 0 matched a
declarative keyword rule and returned `advanceSlots(kwIntent, cfg)` directly. The gate
check — `gate(for: intent).fires(confidence: conf)` — existed only in the branch below
it, the one reached after classification.

`pack-en` is the worst possible pack for that gap. It gates exactly ONE intent
(`Cmd.SendMessage`, policy `always`) and that intent ships FOUR keyword rules: `^ptt$`,
`^push to talk$`, `\bsend\b.{0,30}\bmessage\b`, and a `ping <relative>` pattern. So the
single intent the pack insists on confirming was also the one most likely to arrive by
the path that could not confirm. "Send a message to mom" composed and sent, with no
question asked.

The bypass was intended for the CLASSIFIER — a declarative rule is higher precision than
TF-IDF, which is a statement about confidence. Confirmation policy is not about
confidence, it is about consequence: `always` means ask however sure you are.

**Fix:** the keyword branch consults the same gate before `advanceSlots`, at
**confidence 1.0**. A pattern either matched or it did not, so there is no ambiguity to
gate on, and the three policies land where they should — `always` fires, `when_ambiguous`
does not, `never` does not.

**Found by:** `ConfirmationAndSlotFlowTests` after the taxonomy fixes. Its utterance
("set a reminder…") matched a keyword rule, so four tests failed for the visible reason
and three passed while proving nothing — a "yes" answering a slot prompt is
indistinguishable, at the assertion, from a "yes" answering a confirmation. Guarded now
by `testAKeywordRoutedAlwaysGatedIntentStillConfirms`, plus
`testTheTwoUtterancesTakeTheRoutesTheseTestsAssume`, which fails if a future keyword rule
routes the confirmation tests around the gate again.

### VIK-037 — An open slot's free text was overwritten by a gazetteer canonical (Med) — Fixed

"Set a reminder to drink water" created a reminder named **"Drink Water"**.

`extractAllSlots` runs first and sweeps the whole utterance against every entity table,
including open ones. `remind` carries "drink water" as a hint value, so the slot was
filled with its CANONICAL, title-cased form. `fillOpenTopics` — which derives the topic
from the user's actual words — then skipped the slot, because its guard was
`slots[slot.name] == nil` and the slot was no longer nil.

An open entity's value list is a hint, not a vocabulary (VIK-017). When the slot is the
thing the user is naming, their words are the answer; the gazetteer's capitalisation is a
rewrite of them, and it reaches the user as the title of their own reminder.

**Fix:** `fillOpenTopics` overrides rather than fills-if-empty. Only the three
opening-utterance paths call it, so the mid-flow opportunistic sweep is untouched.

**Found by:** `TopicDerivationParityTests` — 2 of 15 cases, both where the free text
happened to collide with a hint value ("drink water", "take medication"). Exactly the
class of divergence the parity fixtures exist to catch, and exactly why VIK-013 wants
them published by the pack's own build rather than captured by hand.
