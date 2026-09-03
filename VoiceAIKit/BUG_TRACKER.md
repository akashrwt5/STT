# VoiceAIKit — Bug Tracker

Defects found while making the package data-driven. The pack compiler's own
tracker lives in the IntentClassifier repo (`docs/BUG_TRACKER.md`); anything
here is iOS-side, or a contract gap that bites iOS specifically.

**Status lives on the entry, not on the section it sits under.** The `## Fixed` /
`## Open` split stopped being maintained once entries started being fixed in
place, so an item marked Fixed can appear under `## Open`. The table above and
each `###` heading are the authority; the two are checked against each other.

**Summary:** 41 fixed, 16 open.

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
| VIK-010 | data layer | Med | `head.json` declared by every pack, shipped by none | **Fixed** |
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
| VIK-030 | contract | Med | `runtime/routing.json` is decoded and never read — the pack's ladder and `assist_cloud` switch do nothing | **Fixed** |
| VIK-031 | security | **High** | Unresolved turns returned a URL built from pack data, with the user's transcript in its query string | **Fixed** |
| VIK-032 | STT | **High** | A locale the device cannot transcribe was swallowed by `try?` — pack in one language, recogniser in another, silently | **Fixed** |
| VIK-033 | packaging | Med | The package persisted the transcription locale in the HOST app's `UserDefaults.standard` | **Fixed** |
| VIK-034 | packaging | Med | `bundle.json` had TWO independent Decodable models reading different subsets of it | **Fixed** |
| VIK-035 | security | **High** | The host extractor rewrote `bundle.json` before signature verification — every OTA install would fail once signing is on | **Fixed** |
| VIK-036 | NLU | **High** | Keyword-routed intents skipped the confirmation gate — `Cmd.SendMessage` (`always`) sent without asking | **Fixed** |
| VIK-037 | NLU | Med | An open slot's free text was overwritten by a gazetteer canonical — a reminder the user named "drink water" was stored as "Drink Water" | **Fixed** |
| VIK-038 | NLU | **High** | Slot answers were re-classified and cancelled the flow — "Need to go to walk" scored 0.994 as a command and killed the reminder being set | **Fixed** |
| VIK-039 | NLU | **High** | A follow-up answer skipped topic derivation — the carrier, the time and the gazetteer rewrite all survived into the reminder name | **Fixed** |
| VIK-040 | NLU | **High** | Spelled-out times were read into `date_time` AND left in the name — "at nine" gave "call Mukesh nine", "at 9" gave "call Mukesh" | **Fixed** |
| VIK-041 | contract | **High** | Politeness prefixes are not carriers — "Can you remind me to go for a walk" stores the whole sentence as the reminder name | **Fixed** |
| VIK-042 | NLU | Med | A bare hour 1–6 is assumed PM by a rule hardcoded in Swift — "at 3" is always 15:00, and no pack can change it | **Fixed** |
| VIK-043 | NLU | **High** | "tonight" said after its hour resolves to a time already past — a reminder created for a moment that has gone | Open |
| VIK-044 | packaging | Med | `SeedPack.url` picks the vendored pack by STRING sort, so 1.0.9 would beat 1.0.45 | Open |
| VIK-045 | parity | Med | Rolling to the next day: Python adds 24 hours, Swift adds a calendar day — they diverge across a DST boundary | Open |
| VIK-046 | testing | Med | The Swift parity fixtures say "regenerate, never hand-edit" and ship no generator | Open |
| VIK-047 | NLU | Med | A day-only answer re-asks the identical question, then discards a correctly-extracted reminder after three tries | Open |
| VIK-048 | contract | Med | `interrupt_threshold` is fitted against negatives the engine no longer produces | Open |
| VIK-049 | contract | Low | "in quarter of an hour" does not resolve, while "in half an hour" does | Open |
| VIK-050 | parity | **High** | The interrupt bar was a constant in this package (0.75) while the pack and Python said 0.68 — a topic switch happened on one runtime and not the other | **Fixed** |
| VIK-051 | contract | Med | Every iOS pack declared a `model.onnx` the build had just deleted, and shipped a Python pickle no iOS code reads | **Fixed** |
| VIK-052 | contract | Med | The loader's artifact-existence check is fully written and never called, so a manifest can name files the pack does not ship | **Fixed** |
| VIK-053 | contract | Med | The slot-attempt budget existed as three independent hardcoded `3`s — the compiler's literal, Python's class constant and a `>= 3` in this engine — so `policies.limits.max_slot_attempts` was a number no one could change | **Fixed** |
| VIK-054 | parity | **High** | The out-of-vocabulary guard is Python-only. `oov_reject`/`oov_bypass` are not even decoded here, so this runtime fires on utterances the reference engine refuses | **Fixed** |
| VIK-055 | parity | Med | `thresholds.agreement`, `thresholds.semantic` and `limits.session_timeout_s` are shipped by every pack and read by nothing in this package | Open |
| VIK-056 | packaging | Low | iOS packs ship both `.mlpackage` (source) and `.mlmodelc` (compiled) for each head; iOS never opens the packaged form | **Fixed** |
| VIK-057 | packaging | Low | Every pack shipped both CoreML heads, including channels where only one is ever bound | **Fixed** |

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

### VIK-017 — v3 drops the `open` entity flag (**High**) — Fixed

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

### VIK-019 — `dynamic_source` does not say which builtin (Med) — Fixed

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

### VIK-022 — Pack lexicon is missing the "set a reminder" carrier (**High**) — Fixed

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

**That Ask was wrong, and this entry is the correction.** It assumed the ladder was a
design this package had failed to implement. It is not a design at all.

`runtime/routing.json` is not authored anywhere. `content_bundle.py` carries it
VERBATIM out of `spec/examples/3.0/minimal` — its own comment reads "Files taken
verbatim from the fixture" — and re-derives exactly one number inside it. Every pack
ever published shipped a spec EXAMPLE's ladder. Wiring it would have made a fixture
into product behaviour.

It also contradicts everything around it:

* **The engines.** Both are binary below the fire threshold. The reference
  `engine.py` says so in its own words — *"The decision ladder is BINARY:
  `confidence_threshold` and below it the fallback intent"* — and returns
  `NLUResult(type="FALLBACK", intent="GENAI", ...)`. Neither runtime has ever had a
  reprompt step keyed on confidence.
* **ADR-004, the actual design.** Its ladder is eight rules and contains no
  `reprompt` step. Re-prompting is rule 1's MID-FLOW behaviour — *"a garbled slot
  answer is a re-prompt (attempt budget exists for exactly this)"* — which is about a
  frame expecting an answer, not about a confidence score. Low confidence is rule 5
  (clarify) or rule 6 (escalate). So `{"step":"reprompt","when":{"below_confidence"}}`
  pairs a mid-flow verb with a condition from a different rule entirely.
* **ADR-005, the ownership.** It lists `runtime/routing.json` under the Platform
  team, produced by a policy-resolution stage the compiler does not implement.

`assist_cloud.enabled` is the part worth naming separately. It reads as the switch
governing whether an utterance leaves the device for a cloud LLM. ADR-004 makes that
consent a per-user, revocable AVAILABILITY condition resolved at runtime — a
fleet-wide signed pack cannot carry it, and this copy gated nothing. A field that
looks like a privacy control and controls nothing is worse than an absent one.

**Fixed** by deleting it from both sides rather than wiring it: `PackRouting`,
`ResolvedPack.routing` and the loader's decode are gone (replaced by a note at the
declaration site), and the compiler drops `runtime/routing.json` from `CARRIED`. Each
value it duplicated already had exactly one owner — `below_confidence` is
`policies.thresholds.confidence`, `after_attempts` is
`policies.limits.max_slot_attempts`, and the per-slot `reprompt` response key in the
schema is a different mechanism that merely shares the word. The spec and
`routing.schema.json` still define the section; when the ladder is genuinely built it
returns with a consumer.

Two consequences worth knowing:

* `nlu_langpack`'s loader listed `routing` in `_RUNTIME_TABLES`, which is
  `strict`-required — so it would have refused every new pack over a table nothing
  read. Removed there too.
* A pack built after this change has no `runtime/routing.json`, and an SDK build
  from BEFORE this change requires one. New pack + old SDK fails to load. Ship the
  SDK first, or accept that the two move together.

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

### VIK-034 — Two Decodable models of `bundle.json`, each missing what the other reads (Med) — Fixed

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

---

**Fix.** One model. `NLUBundle` decodes `bundle.json` — everywhere: session load
(`BundleDataLoader`), OTA install (`PackValidator`), the C8 token guard
(`NLUPackInstaller`) and path resolution (`VoiceIntentClient`). `NLUPackManifest` is
deleted, and with it the seven types that existed only to describe its fields —
`EngineCompat`, `SignatureInfo`, `LanguageStatus`, `CapabilityStatus`, `ModelArtifact`
top-level (`ModelResolution` and `ModelResolutionError` survive as internal types).
That closes `PUBLIC_API_PLAN.md` §6.1, which deferred the trim specifically so it could
land here rather than twice.

`PackIdentity` is what hosts see now: `PackValidating.extractAndValidate` and
`NLUPackInstaller.preparePack` both return it. The installer and a running session
therefore answer "which pack?" in the same vocabulary, which was the point.

**The dev-pack refusal moved to where it can act.** `PackValidator` gained a step 6 and
a `ValidationError.developmentPackRefused(channel:keyID:)`. Before, the OTA path decoded
a model with no `channel` field, so it could not ask the question at all — a dev pack was
downloaded, verified, staged and ACTIVATED, and the refusal arrived at the next session
load, after the working pack had already been replaced. The `BundleDataLoader` check
stays: the seed pack never passes through this installer, so that path is not redundant.

**The C8 token guard now matches on `checksums_root`, not `version`.** A version is a
label the compiler picks and a rebuild of 1.0.38 is still 1.0.38, so a version match never
established that these were the verified bytes. The digest the signature covers does.

**`Codable` → `Decodable`, and internal.** `NLUPackManifest` was public AND encodable —
the exact shape that produced VIK-035 (decode → modify → re-encode → broken signature).
`NLUBundle` is internal and decode-only; `PackIdentity` does not decode at all. A host can
no longer make that mistake through this SDK's types.

**One dead branch removed.** `resolveModelPaths` preferred a `vocabulary_artifact` key.
`spec/bundle/3.0/bundle.schema.json` sets `additionalProperties: false` on the model entry
and does not list that key, so a pack emitting it fails its own schema. The branch was
unreachable in every pack that can exist; the `vocab.txt` sibling is now the only path.

**Consequence worth knowing:** `PackValidator` and `VoiceIntentClient` now decode
STRICTLY. A pack missing `channel`, `compiler_version`, `required_runtime_features`,
`telemetry_schema_version`, `report_card_summary` or `engine_compat.max_tested_runtime_contract`
is refused at install instead of at session load. All six are `required` in the bundle
schema, so no compliant compiler output is affected — but a hand-edited pack that used to
install and then fail now fails earlier and says why.

**Tests:** `MockPackValidator` produces a complete, strictly-decodable `bundle.json` (the
old one emitted a document the real loader would have rejected, so it was not testing the
loader at all). `PackValidatorTests` gains its first positive-path assertions, run against
the real seed pack: the dev-pack refusal, its inverse under a permissive policy, and the
premise that the seed pack is dev-signed. `NLUPackInstallerTests` gains the case the old
token-guard test could not distinguish — a well-formed staging bundle carrying the SAME
version and different bytes.

Verified on iOS Simulator 26 (full suite green) and against a live OTA install in the STT
app: download → prepare → activate. STT is unaffected by the provenance check because it
runs `.unverifiedForTesting`, and unaffected by the strict `VoiceIntentClient` decode
because it deliberately does not call `voiceClient.start(...)`.

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

---

### VIK-038 — Slot answers were re-classified and cancelled the flow (**High**) — Fixed

"Set a reminder" → *"What do you want to be reminded about?"* → **"Need to go to walk"** →
the reminder was cancelled and a walk activity started.

`handleSlotFilling` ran the intent classifier on **every** slot-filling turn, ahead of any
attempt to fill the slot it had just asked about, and abandoned the flow whenever another
intent came back at ≥ 0.75.

The classifier is trained on COMMANDS. A slot answer is out-of-distribution input for it,
and a confidence score on OOD input is not a quantity that can be thresholded. Measured
against this pack's own weights:

| the user's answer | classified as | conf |
|---|---|---:|
| "Need to go to walk" | `Cmd.ActivityWalk` | 0.994 |
| "clean my hearing aids" | `Help_CleanCare` | 1.000 |
| "charge my hearing aids" | `Help_Battery` | 0.979 |
| "start my workout" | `Cmd.ActivityExercise` | 0.995 |
| "pick up prescription" | `Cmd.VolumeIncrease` | 0.977 |
| "send the report to my boss" | `Cmd.SendMessage` | 0.961 |

Raising the threshold does not help: "start my workout" — a legitimate reminder — outscores
"start transcribing", a real command (0.962). The two are structurally identical and differ
only in whether the object is a device capability or a thing in the world.

For a hearing-aid product the worst cases are the most likely reminders anyone will set:
"remind me to clean my hearing aids" and "remind me to charge my hearing aids" both
cancelled at 0.98+. The flow survived at all only by accident — "call mom", "drink water"
and "buy milk" produce no vocabulary features, so they route out of scope through the
`isVacuous` path.

**Fix:** the probe is gated on what the awaited slot can *refuse*, never on the intent's
name (this package does not interpret intent labels):

| awaited entity | probe? | why |
|---|---|---|
| closed gazetteer | yes | in the list or not — a miss is a fact |
| open free text | no | every utterance is a legal value; nothing to be right about |
| date-time | no | the parser decides, not the classifier |

For `pack-en` the reminder flow (`remind` + `sys.date_time`) no longer interrupts, and the
memory flow (`memory`, 38 values) still does — "increase volume" is not a memory, so it
still switches topic correctly. Reminder follow-up turns now cost no CoreML inference at all.

**Introduced by:** `13653cb` (2026-06-20), *"Add intent interruption handling to slot-filling
(mirrors Python NLUEngine)"*, which inserted the probe at the top of the method. Its worked
example — "change memory to Car" — is command-shaped, so the feature was only ever checked
against interruptions that look like commands. It shipped with no test, and none of the 142
tests covered interruption until now. Live ~2.5 months.

**Open question — ANSWERED, and the answer was the bad one.** The commit claimed it
mirrors Python's `_handle_slot_filling`. That source was read and RUN: Python probes
first (`engine.py`, classify 38 lines above the fill), so the same defect was live on
the reference side, not merely mis-ported.

Its guard `_answers_awaited_slot` rules itself out for exactly this flow — its own
docstring says *"Only CLOSED enum entities are consulted. For an OPEN free-text entity
(e.g. @remind) every utterance is a valid value… there the confidence bar remains the
only signal."* Both of the reminder's required slots (`remind` open, `sys.date-time`)
are unprotected by it.

Reproduced end to end on the real engine with this pack's own weights: "set a reminder"
→ "clean my hearing aids" fulfilled `Help_CleanCare` and lost the reminder. A case the
table above does not list turned out to be the worst of them — **"walk the dog" scores
1.000**. Fixed on the Python side with the same gate as here (the awaited slot's KIND,
never the intent's name), and pinned by `tests/test_slot_interruption_gate.py`.

The lesson worth keeping: this was the first of three defects found in this session
where a fix had landed in Swift and never reached the reference the Swift is
parity-tested against (VIK-040 and VIK-042 were the others). Parity drifts one way
unless something checks.

**Found by:** field report — "set reminder" then "Need to go to walk" started a walk.
**Tests:** `OpenSlotNameDerivationTests.testTheOpenNameSlotNeverInterrupts`,
`.testTheDateSlotNeverInterrupts`, `.testTheClosedMemorySlotStillInterrupts`.

---

### VIK-039 — A follow-up answer skipped topic derivation (**High**) — Fixed

The sibling VIK-037 left open. That fix made `fillOpenTopics` override rather than
fill-if-empty, and said so explicitly: *"Only the three opening-utterance paths call it, so
the mid-flow opportunistic sweep is untouched."* The answer to a slot's own prompt is that
untouched path.

So the same sentence produced two different names depending on where it was said:

| the user says | as the opening | as the answer to the prompt |
|---|---|---|
| "remind me to buy milk" | `buy milk` | `remind me to buy milk` |
| "set a reminder to call the doctor" | `call the doctor` | `set a reminder to call the doctor` |
| "to walk the dog" | `walk the dog` | `to walk the dog` |
| "drink water" | `drink water` | `Drink Water` |
| "I need to pick up prescription" | `pick up prescription` | `Pick Up Prescription` |

The last two are VIK-037 itself, still live on this path: `extract` runs first and returns
the gazetteer's CANONICAL, discarding the rest of the sentence.

**Fix:** an open entity is handled on its own branch and derives the topic the way the
opening utterance already does. The gazetteer is not consulted for it at all — its value
list is a hint, not a vocabulary (VIK-017) — which also removes a fuzzy hazard: `remind` is
`fuzzy: true` and its only fuzzy-eligible synonym is "activity", which "acidity" and
"captivity" are both inside the edit-distance limit of. Closed entities are untouched.

**Tests:** `OpenSlotNameDerivationTests.testTheAnswerToThePromptHasItsCarrierStripped`,
`.testATimeInTheAnswerFillsTheDateSlotAndLeavesTheName`,
`.testOpeningAndFollowUpDeriveTheSameName`, `.testAClosedSlotStillResolvesThroughTheGazetteer`.

---

### VIK-040 — Spelled-out times survive into the reminder name (**High**) — Fixed

```
"Remind me to call Mukesh at 9"      ->  name "call Mukesh"        correct
"Remind me to call Mukesh at nine"   ->  name "call Mukesh nine"   wrong
```

Same meaning, different result — and the time was extracted *correctly* in both cases, so
`date_time` was right while the name was wrong.

`parse` normalises spelled-out numbers to digits before it matches (`normalizeOrdinals` /
`normalizeCardinals`). `strippingDateTime` did not, and all ten of its patterns are written
in `\d`. So "at nine" was invisible to the stripper while `parse` had already read it as
9:00. Step 9 then removed the bare "at" as a leftover connector, stranding the number — the
exact failure step 4's comment warns about for digits ("dinner at 7" becoming "dinner 7"),
reached by the spelled-out door.

**Fix:** a `clockNumber` token that matches digits **or** spelled-out forms, built from
`numberIndex` — the same table `normalizeCardinals` uses, so the two agree by construction —
applied to the two patterns that carry a time marker (`<at|by> N`, `N am/pm`).

Deliberately NOT fixed by calling `normalizeCardinals` inside `strippingDateTime`: this text
becomes the reminder's NAME, and normalising it would rewrite every other number the user
said ("buy nine apples" → "buy 9 apples"). Widening only the marked patterns leaves the rest
verbatim.

**Found by:** field report — device log, `'Remind me to call Mukesh at nine'`.
**Test:** `OpenSlotNameDerivationTests.testASpelledOutTimeLeavesTheNameJustLikeADigitOne`.

---

### VIK-041 — Politeness prefixes are not carriers (**High**) — Fixed

**CLOSED end to end.** The two patterns below ship in `pack-en-v1.0.45`, at the
FRONT of the carrier list, and the ordering is asserted rather than assumed —
`_derive_topic` makes one pass in list order, so a prefix-stripper that runs late
never gets its turn back. Verified against the vendored pack's own bytes:
"Can you remind me to go for a walk" derives "go for a walk".

Two things were fixed alongside it, in the same list, because they are the same
class of defect:

* the optional connector group `(?:to|that|about|of)?` carried no `\b`, so it ate
  the start of the following word — "remind me tomorrow" derived "morrow",
  "remind me office party" derived "fice". Three shipped carriers were affected,
  and so was the first draft of the politeness pattern added here.
* the list named its VERBS (`remind|tell|alert|notify`), so every other phrasing
  kept its wrapper: "nudge me to stretch" was stored verbatim. Three carriers by
  SHAPE replace it. `^\s*\w+\s+me\s+(?:to|about|that|when)\b` is safe because
  of WHERE it runs, not because it is narrow — topic derivation only happens for
  an OPEN slot and `remind` is the only open entity, so the classifier has already
  decided this is a reminder before any of it executes.

The original diagnosis below stands; it is kept because the ordering argument is
the part that is easy to get wrong twice.

```
"Remind me to go for a walk"        ->  name "go for a walk"                        correct
"Can you remind me to go for a walk" ->  name "Can you remind me to go for a walk"  wrong
```

`lexicons/en.json` ships six carriers, all anchored to the start of the utterance:

```
0: ^\s*please\s+
1: ^\s*(?:do\s*n[o']?t|don't|dont)\s+let\s+me\s+forget\b\s*(?:to|about)?\s*
2: ^\s*(?:remind|tell|alert|notify)\s+me\b\s*(?:to|that|about|of)?\s*
3: ^\s*set(?:\s+up)?\s+(?:an?\s+)?(?:reminder|alarm)\b\s*(?:to|about)?\s*
4: ^\s*make\s+sure\s+(?:i|to)\b\s*
5: ^\s*i\s+(?:need|have|want)\s+to\b\s*
```

"Can you remind me…" starts with "Can you", so carrier 2 never matches and nothing is
stripped. The whole sentence becomes the reminder's name. `^please` already sits at index 0,
so the shape was understood — the polite-question form was simply never added.

**Required change** — add to `lexicons/<lang>.json` `carriers`:

```
^\s*(?:can|could|would|will)\s+you\s+(?:please\s+)?
^\s*i\s+want\s+you\s+to\s*
```

**ORDER IS LOAD-BEARING — they must go at the FRONT of the array, before carrier 2.**
`deriveTopic` makes ONE pass in list order and each pattern is `^`-anchored, so a pattern is
only ever tested against the string as it stands when its turn comes:

```
"can you" at the END:      ^remind me  -> no match ("can you …")
                           ^can you    -> strips   -> "remind me to go for a walk"
                           loop ends   -> ^remind me is never retried    STILL WRONG

"can you" at the FRONT:    ^can you    -> strips   -> "remind me to go for a walk"
                           ^remind me  -> strips   -> "go for a walk"    CORRECT
```

This is why `^please` is index 0 today. Any future politeness prefix has the same
requirement.

`lexicons/en.json` is listed in `integrity/manifest.sha256`, so this needs a pack recompile
and re-sign — it cannot be hand-edited into the vendored pack.

**Applies to every language pack**, not just English.

**Found by:** field report — device log, `'Can you remind me to go for a walk'`.

---

### VIK-042 — A bare hour's AM/PM side is decided by a hardcoded rule (Med) — Fixed

**CLOSED, and without the pack field this ticket asked for.** The ask was to move
the `1...6` constant into the pack so a language could disagree with it. There is
no constant left to move: a bare hour now takes the EARLIEST reading still ahead
of us, and the answer comes from the clock.

    05:41  "at 6"                     06:00 today       (was 18:00)
    15:00  "at 3"                     03:00 tomorrow
    any    "medicine tomorrow at 6"   06:00 tomorrow    (was 18:00)

Two rules were measured and rejected before this one, over 288 (now, hour) pairs:

* the old rule guessed the half of the clock BEFORE consulting `now` and looked
  at the time only to rescue a guess that had landed in the past. "wake me at 6"
  at 05:41 was not in the past, so nothing rescued it.
* plain "next future occurrence" breaks 51 cases and fixes 33. Say "at 2" at
  16:00 and both readings fall tomorrow — 02:00 in ten hours, 14:00 in
  twenty-two — so nearest picks 02:00. That is arithmetic, not evidence.

**ACCEPTED COST, on the record:** on a NAMED day both readings are ahead of us,
so the earliest is always the morning one — "meeting tomorrow at 5" resolves to
05:00. Saying "5 pm" fixes it. There is genuinely no signal on a named day; the
guess was not removed, its scope was narrowed to the cases where nothing else
could decide. Asking ("Monday, 5 in the morning or the evening?") is the honest
answer there and belongs with the confirmation work.

**Two bugs this fix introduced, both caught by regenerating the golden corpus and
reading the diff rather than by the suite going red:**

* `"at noon"` resolved to midnight. The old rule left 7–12 alone, so noon
  survived by luck. Read as a bare 12 it is offered 00:00 as its other half. A
  named time is not ambiguous; `Clock.isNamedTime` now says which hours came from
  a word rather than a digit.
* `"3 in the afternoon"` resolved to 03:00. The first attempt at the noon fix
  excluded every named period — but the 3 came from the user and the period is
  what says which 3 they meant. It has to be the flag, set only where the hour
  itself came from the name.

The original analysis below is kept for the reasoning, not the remedy.

"remind me to go for a walk tomorrow at 3" schedules **15:00**. There is no way for a pack
to ask for anything else.

`PackDateTimeParser.pickFutureHour`, line 627 — the branch taken when the user gave no
am/pm and no period word:

```swift
default:
    h24 = (1...6).contains(hour) ? hour + 12 : hour
```

| the user says | resolves to | |
|---|---|---|
| at 1, 2, 3, 4, 5, 6 | 13:00 … 18:00 | +12, assumed PM |
| at 7, 8, 9, 10, 11, 12 | 07:00 … 12:00 | left alone, assumed AM |

As a heuristic it is mostly right — "meet me at 3" usually is 15:00, "at 9" usually is 09:00.
It breaks at the edge: **"wake me at 6" becomes 18:00.**

The same-day escape hatch does not apply to a named day:

```swift
if candidate <= now, calendar.isDate(day, inSameDayAs: now), period == nil { …try the other half… }
```

`isDate(day, inSameDayAs: now)` is false for "tomorrow", so a future day always keeps the
biased hour — which is exactly the reported case.

**Why this is a defect and not a preference:** the constant is in Swift, not in the pack.
`grep -rn "1\.\.\.6" Pack/ NLU/` returns this one line, and `datetime_grammar` carries no
field that could override it — it has `time_format: "12h"` and `am_pm`, nothing about which
half of the clock a bare hour belongs to. So every language pack inherits an English-speaking
assumption it cannot express disagreement with. That is VIK-001's shape: a language decision
compiled into the engine, invisible, with no error when it is wrong for a locale.

**Two possible fixes:**

1. *Narrow the range* (`1...4`?). Fixes "at 6", still hardcoded, still not pack-driven. A
   patch, not a fix.
2. *Move it to the pack.* Add to `datetime_grammar.grammar`, e.g.
   `"bare_hour_pm_range": [1, 6]`, read it in `PackDateTimeParser.init`, and default to the
   current `1...6` when a pack omits it so no existing pack changes behaviour. One engine
   line plus a pack field, and a 24-hour or non-English pack can then state its own
   convention.

(2) is the one that matches this package's contract. It needs a pack recompile and re-sign,
so it lands with the other pack-side items (VIK-041).

**Found by:** field report — "remind me to go for a walk tomorrow at 3" scheduled 15:00, and
the user expected the morning.

---

## Open

### VIK-043 — "tonight" said after its hour resolves into the past (**High**)

```
20:17   "remind me tonight"   ->   18:00 TODAY      already gone
```

`tonight` is bridged onto the `evening` period (VIK-016), whose hour is 18. Said at
any point after 18:00 the resolved time is behind the caller, and a reminder is
created for a moment that has passed.

Both runtimes, same shape. The guard that exists compares DATES only:

```python
if explicit_day and base_day.date() < now.date():   # entities.py
```
```swift
if dayExplicit, calendar.startOfDay(for: baseDay) < calendar.startOfDay(for: now)
```

A spent hour earlier the same day passes it. The push-to-tomorrow one line above is
skipped because `explicit_day` / `dayExplicit` is true — "tonight" names a day.

Found while verifying VIK-042's "never resolves into the past" invariant: 7080
combinations produced exactly six past results and all six were this. Deliberately
not fixed inside that change — a bare-hour commit is the wrong place for it, and the
right answer is a product decision. At 22:00 "remind me tonight" could mean tomorrow
evening (but the user said *tonight*), or it could be the case to ask about. Note the
engine already has the machinery: a day with no usable time can be returned with
`time_explicit=False`, which parks the day and prompts for the hour.

**Needs:** a decision, then the same change in both runtimes.

### VIK-044 — the seed pack is chosen by string sort (Med)

`VoiceAISeedPackEN.url` scans the resource directory and takes the last name in
lexicographic order:

```swift
names.filter({ $0.hasPrefix("pack-en-v") }).sorted().last
```

Scanning is deliberate and correct — the API that splits a name into stem and
extension returns a silent nil on `pack-en-v1.0.45`, which is indistinguishable from
"the resource is missing". The SORT is the problem: it compares strings, so
`pack-en-v1.0.9` beats `pack-en-v1.0.45` because `9` > `4`.

Harmless today — one pack ships, and 1.0.38 vs 1.0.45 happens to sort correctly. It
bites the first time two packs sit side by side across a version boundary like 9 → 10,
and it bites silently: the app loads an older pack and everything still works, slightly
wrong.

**Fix:** compare version components numerically.

### VIK-045 — the two runtimes roll to the next day differently (Med)

Python adds twenty-four hours; Swift adds a calendar day:

```python
dt += timedelta(days=1)                                    # entities.py, 5 sites
```
```swift
calendar.date(byAdding: .day, value: 1, to: candidate)     # PackDateTimeParser, 3
```

Identical except across a DST boundary, where they differ by an hour. Pre-existing on
both sides and untouched by the VIK-042 work, which followed each file's existing
pattern rather than introducing a third.

No impact for a pack in a zone without DST, which is why it has not surfaced. It is a
parity defect the fixtures cannot see: the golden corpus is captured at one fixed
instant, and neither runtime's tests cross a transition.

**Fix:** pick one semantic — a calendar day is the right one for a wall-clock reminder
— and make both do it, with a fixture on each side of a transition.

### VIK-046 — the parity fixtures say "regenerate, never hand-edit" and ship no generator (Med)

`Tests/VoiceAIKitTests/Fixtures/topic_expectations.json` carries:

> "Generated from packages/runtime/nlu_engine/entities.py + engine.py::_derive_topic.
> Regenerate, never hand-edit."

There is no script in either repo that does it. The IntentClassifier side has
`scripts/ci/capture_en_datetime_golden.py` for its own corpus; this one has nothing,
so "regenerate" means someone reconstructing the procedure from the note.

That is not theoretical: both Swift fixtures went stale twice in one session and were
caught only because they were checked by hand against the reference before building.
`reference_expectations.json` needs the same script.

**Fix:** commit the capture script next to the fixtures, and run it in CI so a
reference change that moves a fixture fails the build instead of waiting to be noticed.

### VIK-047 — a day-only answer re-asks the same question, then throws the reminder away (Med)

```
USER   "remind me to pay rent on friday"
ASSIST "When should I remind you? You can say things like '9am', ..."
USER   "friday"
ASSIST "When should I remind you? You can say things like '9am', ..."     identical
USER   "friday"
ASSIST  ... same again
USER   "friday"
ASSIST "Sorry, I'm having trouble with that. Let's try something else."
```

The parked day survives correctly — answering "9am" at any point still yields Friday
09:00 — so the state machine is sound. Two things are not:

* the re-prompt is byte-identical to the first ask. It does not say that the day is
  already known, or that a time of day is the missing part, so a user who believes
  they answered has nothing to correct.
* at `MAX_SLOT_ATTEMPTS` the flow is abandoned and the NAME goes with it, though
  "pay rent" was extracted correctly on turn one. Only the hour was ever missing.

Anything carrying a time works: "9am", "9", "friday at 9", "friday morning", "in the
morning". Only a bare day does not.

**Needs:** a second prompt that names what is already held ("What time on Friday?"),
and a decision about whether a spent budget should discard a half-filled reminder or
hand it back. Both are content and product changes, not engine ones.

### VIK-048 — `interrupt_threshold` is fitted against negatives the engine no longer produces (Med)

`slot_thresholds.json` documents its own fit:

> "negatives: OPEN free-text entity surface forms … Closed enum slots are protected by
> precedence instead (`NLUEngine._answers_awaited_slot`), not by this bar."

and `fit_slot_thresholds.py` selects them accordingly (`if not spec.get("open"): continue`).

After VIK-038 an open slot is never probed at all, so the entire negative set the value
was fitted against can no longer occur. The bar now applies only to CLOSED enum slots —
the ones its own provenance says are protected by precedence rather than by it.

Nothing is broken: 0.68 still functions and errs conservative, since a higher bar means
fewer interruptions and the fit's objective was "fewest flows destroyed". But the
number describes a situation that no longer exists, and with those negatives gone the
constraint relaxes — the bar could likely be lower and catch more genuine topic
switches.

Blocked in practice: `fit_slot_thresholds.py` reads `content/nlu_entities.json`, which
does not exist (the file lives at `language_packs/<lang>/nlu_entities.json`), so the
refit cannot be run as it stands. That belongs in the IntentClassifier tracker; it is
noted here because the value it produces ships in the pack and this runtime reads it.

**Fix:** repair the path, refit against a negative set that matches how the value is
now used, and update the provenance note.

### VIK-049 — "in quarter of an hour" does not resolve (Low)

```
"remind me in half an hour"          ->  +30 min      ✓
"remind me in quarter of an hour"    ->  no match
```

`clock_idioms` carries `half_an_hour` but no quarter-hour equivalent, and the
relative-duration path needs a digit ("in 15 minutes" works). Same class as VIK-014: a
phrase the grammar could express and does not.

**Ask:** add the idiom to `clock_idioms` in `datetime.json`, in every language.

### VIK-050 — the interrupt bar was a constant here and a number in the pack (**High**) — Fixed

`NLUEngine` carried:

```swift
/// Mirrors Python NLUEngine.INTERRUPT_THRESHOLD = 0.75.
private static let interruptThreshold: Double = 0.75
```

The comment is what makes this hard to see: it claims parity, and it is wrong. 0.75 is
Python's `DEFAULT_INTERRUPT_THRESHOLD` — the fallback for a schema that OMITS the key
— and `engine.py` puts a warning directly above it:

> "The live value is CONTENT-OWNED (`content/platform.yaml`, per-language via
> overlay) and fitted by `nlu_training.fit_slot_thresholds`; read it from
> `self.interrupt_threshold`, not from here."

Python reads `interrupt_threshold` out of the schema. `pack-en` carries **0.68**, and
`runtime/policies.json` carries the same 0.68 under `thresholds.interrupt`. So Swift
mirrored Python's fallback instead of Python's value, and the two runtimes disagreed
on every probe scoring in **[0.68, 0.75)**.

What that looks like. The user is part-way through changing a memory — the flow has
asked *"which memory?"* — and says "increase the volume", which the classifier scores
0.71:

```
Python:  0.71 >= 0.68  ->  topic switch, volume goes up
Swift:   0.71 <  0.75  ->  ignored, asks "which memory?" again
```

Same pack, same words, two answers — the VIK-025 family. The blast radius is bounded
by the VIK-038 gate: the probe only runs for CLOSED gazetteer slots, so the reminder
flow (open name + date-time) never reached this code and only the memory flow could
diverge. Bounded is not harmless; it is one of the two flows the product ships.

**Fixed** by making the bar a required initializer parameter with no default —
matching the rule this file already states for its word lists ("NOTHING HERE DEFAULTS
TO ENGLISH ANY MORE", VIK-001) — and having `PackEngineFactory` pass
`pack.policies.thresholds.interrupt`. `testTheInterruptBarComesFromThePackNotTheEngine`
pins both sides of the bar and reads its bounds from the pack, so retuning the content
retunes the test rather than breaking it.

Correction to this tracker: VIK-048 ends "the value it produces ships in the pack and
this runtime reads it." That was not true when it was written. It is true now.

### VIK-051 — every iOS pack declared a model it had just deleted (Med) — Fixed

`bundle.json` in `pack-en-v1.0.45-ios`:

```json
"artifact": "models/intent/en/model.onnx",
"format": "onnx",
```

There is no `model.onnx` in the pack, and there never was one in any iOS pack. The
compiler's `assemble_pack.py` builds three slices from one staged tree, and its iOS
slice deleted the ONNX from disk while leaving the manifest entry that names it:

```python
def mod_ios(s_dir, s_man):
    onnx_file = ...model.onnx
    if onnx_file.exists():
        onnx_file.unlink()          # file gone
    for key in ["tflite_artifact", "tflite_int8_artifact"]:
        intent.pop(key, None)       # ...but "artifact"/"format" left behind
```

`mod_android`, ten lines below, does both halves correctly. The bug is one function's
asymmetry. The same function never removed `labels.pkl` either — a Python pickle,
1.1 KB, with no iOS consumer: the labels iOS reads are `labels.json`, which the
compiler DERIVES from that pickle precisely so the two cannot disagree. Shipping the
source pickle puts a deserialization-primitive artifact in a signed medical bundle for
no runtime benefit.

**Fixed** in the compiler, not here. `artifact`/`format` cannot simply be dropped the
way the tflite keys can — both are `required` in `bundle.schema.json` and
non-optional in this package's `ModelSpec` — so they are made true instead. The format
enum already admits `mlmodelc-ref`, which is exactly what ADR-005's bundle layout
means by `model.{onnx|mlmodelc-ref}`:

```json
"artifact": "models/intent/en/IntentClassifier.mlmodelc",
"format": "mlmodelc-ref",
```

That names the file `iOSModel(_:)` actually opens. The swap and the ONNX deletion are
now conditional on the compiled head being present in the slice, so a slice built
without one keeps its ONNX and keeps describing it — the manifest is never wrong in
either direction. `labels.pkl` is dropped from the iOS slice; `labels.json` stays.

Not fixed here: `models/semantic_head/shared/head.json` (VIK-010) is declared by every
pack and shipped by none. That one is a different shape — the compiler emits the
declaration because the schema requires `artifact` and there is no JSON head to point
at — and closing it needs a spec change, not a slice fix.

### VIK-052 — the artifact-existence check is written and never called (Med)

This package contains everything needed to have caught VIK-051 at load time:

```swift
/// Every artifact path this spec declares, for existence checking.
var declaredPaths: [String] { ... }                       // NLUBundle.swift

/// Declared artifacts allowed to be absent.
public let toleratedMissingArtifacts: Set<String>         // PackIntegrity.swift
```

plus a dedicated error case, `declaredArtifactMissing(path:)`, whose documentation
explains that `head.json` is tolerated "by policy". Nothing calls `declaredPaths`, and
nothing reads `toleratedMissingArtifacts`. Both are dead. `declaredArtifactMissing` IS
thrown, but only from two specific places in `BundleDataLoader` — the weights path and
the variant's own model choice — never over the manifest as a whole.

So the tolerance list is not what let `model.onnx` through. Nothing looked. A public
policy field that documents a safety behaviour the code does not perform is worse than
no field: it is what makes a reviewer stop looking.

**Ask:** walk `manifest.models`' `declaredPaths` after integrity verification and
throw `declaredArtifactMissing` for anything absent and not tolerated.

**Order matters, and this is the reason it is still open.** `model.onnx` is NOT in
`toleratedMissingArtifacts`. Turning the check on before the compiler fix in VIK-051
reaches a published pack would refuse EVERY iOS pack, including whatever is live over
OTA. The compiler fix ships first; this follows. When it does, `.mlmodelc` and
`.mlpackage` are directories, so the check has to test for existence, not for a
regular file.

### VIK-053 — the slot-attempt budget was three independent 3s (Med) — Fixed

`runtime/policies.json` declares the budget:

```json
"limits": {"max_slot_attempts": 3, "session_timeout_s": 120}
```

`PackPolicies.Limits` decoded `maxSlotAttempts` correctly. Nothing read it. The engine
counted against a literal instead:

```swift
// NLUEngine.swift, before
session.slotAttempts += 1
if session.slotAttempts >= 3 {
```

Same shape as VIK-050, but with a third copy. Tracing it back, the number was
hardcoded at every hop:

| Where | Was |
|---|---|
| `content_bundle.compile_policies` | `"limits": {"max_slot_attempts": 3, ...}` — a literal in the compiler, not read from content |
| `engine.py` | `MAX_SLOT_ATTEMPTS = 3` — a bare class constant, so no language pack could override it |
| `NLUEngine.swift` | `session.slotAttempts >= 3` |

Three values that only agreed because all three were typed as `3`. The pack field
looked authoritative and was decorative — change it to 5 and every runtime would still
abandon at 3.

Unlike VIK-050 this was NOT a live divergence: both engines abandon after three failed
turns today, and they agree. It is the mechanism that was broken, not the behaviour —
and it is the mechanism that decides whether the next content change lands.

**Fixed** end to end, in the shape the other content-owned values already use:

```
language_packs/en/platform.yaml   max_slot_attempts: 3          (SOURCE, authored)
   └─ content_source assemble  →  nlu_schema.json
        ├─ engine.py            self.max_slot_attempts = schema.get(...)
        └─ compile_policies    →  runtime/policies.json  limits.max_slot_attempts
                                   └─ NLUEngine(maxSlotAttempts:) via PackEngineFactory
```

Python keeps `DEFAULT_MAX_SLOT_ATTEMPTS = 3` and the `MAX_SLOT_ATTEMPTS` alias
(`scripts/test_sprint1_hardening.py` reads it), and this package keeps `Limits()`'s
`?? 3`, but both are now the pack-omits-the-section fallback rather than the live
value — the same distinction `engine.py` already drew for the interrupt threshold.

Also fixed while in there: `compile_policies` reads `schema["max_slot_attempts"]`
instead of a literal, and `content_source` carries the key. That second half matters —
`PLATFORM_KEYS` and the compiled layout are two hand-maintained lists of the same keys,
and the assert between them exists because `interrupt_threshold` was once accepted by
one and dropped by the other, silently sending the engine back to its fallback.

`limits.session_timeout_s` is deliberately left as a literal: no runtime reads it on
either side. See VIK-055.

### VIK-054 — the out-of-vocabulary guard is Python-only (**High**)

`runtime/policies.json` ships both halves of the OOV guard:

```json
"oov_reject": 0.25, "oov_bypass": 0.97
```

`PackPolicies.Thresholds` does not have them. Its `CodingKeys` are `confidence`,
`interrupt`, `semantic`, `agreement`, `uncertain_confirm_below`,
`uncertain_confirm_floor` — the two OOV keys are not decoded, and the string `oov`
does not appear anywhere in this package, Sources or Tests.

**What the guard is for.** The TF-IDF vocabulary is finite (1317 entries for the pruned
head). A word outside it is not "weighted low" — it does not reach the model at all:

```
user said:      "help me find a paper"
model received: "help me find"            "paper" has no slot in the vocabulary
model answered: Help_FindMyHearingAids @ 0.771
```

0.771 is an honest score for the input the model was given. The input was not what the
user said. `engine.py` states the consequence directly: *"This cannot be done by tuning
a threshold — the confidence is honest about the input the model was given."* So the
unknown words are consulted separately: at or above `oov_reject` of the tokens being
unrepresentable, the turn goes to fallback whatever the confidence.

**Why the second half is not optional.** Entity values are out-of-vocabulary BY NATURE
— a contact name, a brand, a free-text reminder topic can never all be in a finite
vocabulary. Measured on this pack's own weights:

```
'send a message to john'   oov 0.25, conf 1.000   <- a real command
'stream from netflix'      oov 0.33, conf 0.996   <- a real command
'help me find a paper'     oov 0.25, conf 0.771   <- out of scope
```

The first and third have the SAME ratio. The ratio cannot separate a slot value from a
foreign topic; the confidence can, which is why the guard stands down above
`oov_bypass`. Adding that condition kept the out-of-scope reduction (10 → 5) and
returned 7 correct commands the bare ratio was refusing.

The compiler emits the pair from one statement and says why:

> "A runtime that ignores these fires on utterances the reference engine refuses...
> `oov_bypass` is not optional. A client that reads the ratio without it refuses entity
> values... Shipping one half of a pair is how the device/server temperature diverged
> (B8); the two are emitted from the same statement so they cannot separate."

**Today's divergence.** "help me find a paper" is routed to fallback by Python and
fires `Help_FindMyHearingAids` here. That is a wrong action, which is the metric the
pack is gated on (`report_card.wrong_action_count: 28`), and it is the failure mode
this guard was fitted to remove.

**Ask:** decode both keys, add an `oovRatio(_:)` to `PackIntentClassifier` over the
vocabulary it already holds, and apply the guard where Python does — after the guards,
before the fire test, so it can only ever withhold an action and never cause one.
Implement both halves in one change; one half alone is worse than neither.

### VIK-055 — three more policy fields nothing here reads (Med)

Same shape as VIK-050/053, smaller stakes, recorded so the set is complete.

**`thresholds.agreement` (0.5).** The relaxed bar for a turn two INDEPENDENT
recognisers agree on. Python applies it twice — `fire_bar = agreement if corroborated
else threshold`, and as the semantic-rescue accept bar when TF-IDF and the head land on
the same real intent. Over a 57-class head a correct prediction diffuses across sibling
classes: `"turn it up its too quiet"` has the keyword rule and the model both saying
`volume.increase`, but "quiet" splits mass with `volume.decrease` and the top sits at
0.66. Python fires it; this engine's bar is flat (`conf < schema.confidenceThreshold`,
`NLUEngine.swift`) and drops it. Measured: corroborated keyword turns are 99.2% correct
(n=118) and 100% correct in the 0.50–0.70 band.

Note the value is EVIDENCE STRENGTH, not a confidence — `engine.py` is explicit that
the reported confidence stays the calibrated probability and only the bar moves.
Implementing this as "raise the score for corroborated turns" would put a second scale
back into the confidence field, which is the defect that ladder was rebuilt to remove.

This package has no corroboration concept to hang it on yet. Its gate is
`confidence >= confidenceThreshold && margin >= gapThreshold`, a different mechanism —
and worth noting on its own: `gap` is read from the WEIGHTS blob
(`weights["conf_gap_threshold"] as? Double ?? 0.20`) directly beneath a comment saying
*"Thresholds come from the pack's policy table; the weights carry their own copy but
policy is the contract."* The code does the opposite of its comment, and
`conf_gap_threshold` is in no policy table at all.

**`thresholds.semantic` (0.4).** Decoded, never read. Not a defect while
`cascade.json` has the semantic stage disabled — but it is live the moment the pack
enables it, and the pack is what decides that, so it must be wired before that switch
is flipped rather than after.

**`limits.session_timeout_s` (120).** Read by neither runtime. It is also a literal in
`compile_policies` (see VIK-053), so unlike the others it is not even content-owned
yet. Decide what it means before wiring it: session expiry is a facade concern here,
not an NLU-engine one.

### VIK-054 — the out-of-vocabulary guard is Python-only (**High**) — Fixed

(Statement of the defect is in the entry above; this records the fix.)

Implemented where the reference implements it, with both halves or neither.

`PackTFIDFVectorizer` gained `unigrams` — the vocabulary minus bigram keys,
precomputed, because the guard runs every turn over up to 4718 entries — and
`oovRatio(_:)` over the tokenizer that was already there. That tokenizer is
`(?u)\b\w\w+\b`, the same rule the reference uses, which is what makes the two
ratios the same number rather than two approximations of one.

Verified by transcribing the Swift implementation into Python and running it
against the SHIPPED `intent_classifier_weights_full.json` (5896 terms, 1472 of
them unigrams) beside the reference tokenizer:

```
utterance                                       swift  python  match
send a message to john                          0.250   0.250    YES
stream from netflix                             0.333   0.333    YES
help me find a paper                            0.250   0.250    YES
turn off toshiba                                0.000   0.000    YES
what is the weather in bangalore tomorrow       0.143   0.143    YES
```

Those are the numbers the guard was fitted on, reproduced exactly. At
`oov_reject: 0.25` / `oov_bypass: 0.97` the verdicts come out as designed: the
two real commands pass on confidence, and "help me find a paper" (0.771) is
withheld.

`IntentClassifying` gained `oovRatio(_:)` with a protocol-extension default of
`0`, which DISABLES the guard for any conformer that cannot report a
vocabulary — the reference says the same in as many words ("Returns 0.0 when the
backend cannot report a vocabulary, which disables the guard rather than
rejecting everything"). Test doubles and any future non-TF-IDF stage land there.

`policies.thresholds.oov_reject` / `oov_bypass` are now decoded, as Optionals,
and `NLUEngine` applies the guard only when it has BOTH. That is not defensive
style: shipping one half is worse than shipping neither, because the ratio alone
refuses entity values, which are out-of-vocabulary by nature.

Placed immediately before the fire test, as in the reference, so it can only
withhold an action and never cause one.

One knowing difference, recorded rather than hidden: the reference runs this
guard BEFORE semantic rescue is attempted, so a blocked turn never reaches
rescue. Here rescue already happened inside `classifyAsync`, so a rescued turn is
guarded on the rescue's confidence. Moot while the pack disables the semantic
stage — and it is exactly the kind of ordering that becomes a divergence the day
it is enabled, which is why it is written down.

### VIK-010 — `head.json` declared by every pack, shipped by none (Med) — Fixed

The compiler declared `models/semantic_head/shared/head.json` whenever a
`SemanticHead.mlpackage` existed, and produced that JSON never. The original code
carries the author working the problem and giving up:

```python
# `artifact`, `format`, and `model_version` are REQUIRED by the schema.
# So we can't just add a semantic_head with ONLY a coreml_artifact.
```

The premise is right and the conclusion is not. Those three keys are required
*within* a model entry — but `models.semantic_head` ITSELF is optional:
`bundle.schema.json` requires only `models.intent`. The way out was one level up.

So a semantic head is now declared when there is one to declare — when
`semantic_head.json` exists beside the trained model, in which case it is copied
to `head.json` and the `.mlpackage` rides along as `coreml_artifact` — and is not
declared or shipped otherwise. The stage is disabled in every pack we build
(`semantic_rescue_enabled: false`), and enabling it needs a new pack regardless,
because `cascade.json` lives inside the pack.

Removes 92 KB from the pack and, with VIK-051, empties the reason
`toleratedMissingArtifacts` existed.

### VIK-052 — the artifact-existence check is written and never called (Med) — Fixed

Wired as `BundleDataLoader.verifyDeclaredArtifacts`, running after integrity and
before any section is read, so a pack fails on its manifest's own promise rather
than at the first artifact that happens to be needed. `existsAtPath` without
`isDirectory:` on purpose — `.mlmodelc` and `.mlpackage` are DIRECTORIES, and a
check demanding a regular file would refuse every CoreML pack.

`toleratedMissingArtifacts` is now a LEGACY list of exactly two exact paths —
`head.json` (VIK-010) and `models/intent/en/model.onnx` (VIK-051) — both fixed in
the compiler, both listed only so that packs built before those fixes, including
the seed pack vendored in this repo, keep loading while the first corrected pack
is built. **Both entries are to be deleted once no supported pack declares
them**, returning the set to empty, which is the state it should live in. A
tolerance list that accumulates is how a check stops being one.

Verified against the vendored `pack-en-v1.0.45-ios`: 7 declared artifacts, 2
missing, both in the legacy list, nothing else — so the check is live for any NEW
drift today and refuses nothing that ships today.

Not covered by a test yet: asserting the refusal needs a mutated pack, and
`checksums_root` binds `bundle.json` to the manifest, so the mutation has to go
through the same helper `PackLoadingTests` uses for its integrity cases. Worth
adding; not worth blocking this on.

### VIK-056 — iOS packs shipped the source form of every model (Low) — Fixed

Each CoreML head shipped twice: `.mlpackage` (source) and `.mlmodelc` (compiled).
iOS never opens the packaged form when the compiled one is present —
`ModelSpec.iOSModel(_:)` returns `coreml_compiled_artifact` first, and
`MLModel(contentsOf:)` REQUIRES `.mlmodelc` while `compileModel(at:)` REJECTS
one, so the two are not interchangeable and the source form has no device
consumer at all.

The iOS slice now drops each `.mlpackage` and its manifest key, each conditional
on its OWN compiled counterpart having shipped, so a slice built without
`--coreml-compiled` keeps the only model it has. The universal slice is
untouched: that is what model tooling and OTA debug read, which is the
environment-conditional split the packaging review asked for (its P1-NEW-2).

Measured on the shipped pack: **7.1 MB → 5.6 MB**, with the manifest still
schema-valid and every declared artifact present on disk.

### VIK-057 — the channel now decides which heads ride along (Low) — Fixed

A pack carries two CoreML heads: the RFE-pruned one (~1317 features, 88.57% on
the honest holdout) and the full-vocabulary one (~4718, 90.20%).
`BundleDataLoader` defaults to `.full` and NO production path passes a variant —
`VoiceIntentPack.swift` and `VoiceIntentSession.swift` both call `load` without
one — so outside an A/B experiment or a test, the pruned head is loaded by
nobody and shipped to everybody.

Now:

| channel | heads |
|---|---|
| `dev` | both, so a variant can be flipped without republishing |
| `beta`, `production` | the full head only (production cannot be fatter than beta) |

**No change in this package.** The `.full` path needs
`coreml_full_compiled_artifact`, `intent_classifier_weights_full.json` and
`calibration.json`'s `temperature_coreml_full`; all three are present in every
channel, so an unchanged SDK loads a beta pack. Verified against the schema and
the shipped pack rather than reasoned about.

Three things make it safe rather than merely smaller:

**The pruned head is a TRIPLE, not a file.** Its `.mlmodelc`, its own
vocabulary/idf in `intent_classifier_weights.json`, and its own fitted
`temperature_coreml`. `ClassifierVariant` says why: "Mixing legs produces a shape
mismatch at best and plausible-looking wrong confidences at worst, which is why
`resolveClassifier` binds all three together or throws." All three leave, or
none — asserted per channel in the compiler's own check.

**`artifact` is repointed LAST.** An earlier revision of this change set
`artifact` to the pruned `.mlmodelc` and then deleted it two blocks later — the
exact VIK-051 defect, reintroduced one channel over, caught by the invariant
check and not by reading. It now names the head the runtime actually binds (the
full one) and is computed after every strip.

**CI refuses the bad build.** A non-dev build without the full compiled head
would produce a pack with no head the device can bind. That fails at load with
`declaredArtifactMissing` — loud, but on a device instead of in CI —
so `assemble_pack` refuses it up front.

Measured on the shipped pack: dev ~5.6 MB, beta/production ~4.5 MB.

**The cost, recorded rather than buried.** This rides on `channel`, which is a
TRUST axis — ADR-005 Part 11: "channel + signing-key id in the manifest lets
production runtimes refuse dev-signed artifacts categorically." Overloading it
means there is no way to build "dev channel, production contents", which is
exactly what isolates whether a field bug comes from the artifact set. Accepted
deliberately: the alternative is a second axis every reader must keep straight,
and `bundle.json` is `additionalProperties: false` so it is a spec change either
way. If that debug need arrives, it arrives as an explicit override flag.

**Consequence for this repo:** the vendored seed pack must stay `channel: dev`.
`PackLoadingTests.testFullVariantBindsItsOwnWeightsAndTemperature` loads it with
`variant: .pruned`, which only a dev pack carries — the test now doubles as the
statement of what a dev pack is.

