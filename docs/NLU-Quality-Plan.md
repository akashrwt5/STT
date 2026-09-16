# NLU quality plan — consolidated, priority-ordered, and costed

**Scope: the VoiceAIKit package** (`VoiceAIKit/Sources/VoiceAIKit/…`) and the
content that feeds it (`IntentClassifier/language_packs/en/`,
`packages/buildtime/nlu_compiler`). Nothing in this plan describes any other code
path in the repository.

**What it consolidates.** Every finding from the four data-based audits and the
parity audit, resolved into one ordered set of work items:

| source | covers |
|---|---|
| [`QADataBasedDecision_VOlumeIncrease.md`](./QADataBasedDecision_VOlumeIncrease.md) | one command intent, 34 phrases; the help-guard defect; the keyword-rule audit |
| [`QADataBasedDecision_Help.md`](./QADataBasedDecision_Help.md) | 24 `Help_*` intents, 400 rows |
| [`QADataBasedDecision_Cmd_Reminders_Fallback.md`](./QADataBasedDecision_Cmd_Reminders_Fallback.md) | 12 `Cmd.*` intents, both reminder intents, the 2,197-row out-of-scope corpus |
| [`QADataBasedDecision_SingleTokenCollapse.md`](./QADataBasedDecision_SingleTokenCollapse.md) | the engine-level collapse mechanism underneath several of the above |
| [`../VoiceAIKit/docs/things-to-pull-from-android.md`](../VoiceAIKit/docs/things-to-pull-from-android.md) | cross-runtime parity gaps and ticket numbers |

§6 is a traceability table: every finding in those documents maps to an item here,
or is explicitly listed as deliberately not actioned.

---

## 1. Expected improvement — measured before the plan was written

This section exists because a plan whose value is asserted rather than measured is
how the VIK-055 two-way design shipped and had to be replaced. Every item below
that **can** be simulated **was** simulated, on the full 5,411-row QA corpus,
through the iOS-faithful ladder.

### 1.1 Metrics

| metric | what it counts | why |
|---|---|---|
| **match** | rows whose final intent equals the QA label | the familiar number; least trustworthy, because the corpus mislabels heavily |
| **false-fire** | rows the corpus labels `Default Fallback Intent` that reach a **state-changing** intent | the cleanest safety signal — 2,197 rows, and a label of "out of scope" is rarely wrong |
| **wrong-act** | any row, any sheet, where a **state-changing** intent fires and the label says otherwise | total harm surface |

"State-changing" excludes `Help_*`, the fallback, and the nine read-only `Cmd.*`
intents (`Cmd.BatteryLevel`, the `Cmd.Activity*` family).

### 1.2 The projection

```
corpus = 5,411 rows
```

| stage | match | false-fire | wrong-act | status |
|---|---:|---:|---:|---|
| **base — what ships today** | 4,729 (87.4%) | **39** | **92** | measured |
| + P1 help-marker, both directions | 4,731 | 39 | 91 | **simulated** |
| + P2 class-aware degeneracy guard | 4,735 | **30** | **81** | **simulated** |
| + P0 `down`/`up` training data | — | **22** | **70** | bounded |
| + P4 `MemoryChange` taxonomy | **4,785 (88.4%)** | 22 | 70 | bounded |

**Net expected effect of the whole plan:**

```
wrong actions   92 -> 70     -24%
false fires     39 -> 22     -44%
match        87.4% -> 88.4%   +1.0 point
```

**And one figure that is not an improvement at all, but belongs here anyway.**
About 306 of the 674 rows the corpus scores as misses are not failures — 232 slot
answers run in the wrong mode, ~74 out-of-scope rows mislabelled `Help_*`. Correct
the corpus and **the same unchanged code measures 92.4%, not 87.4%**. That is
**M0**, the first item in §2. It changes nothing on the device; it is listed first
because the 22 rows the rest of this plan moves cannot be seen inside 306 rows of
noise.

### 1.3 Read this before quoting those numbers

**Accuracy barely moves; safety moves a lot.** That is not a disappointing result,
it is the expected one, and it is the fourth time this corpus has said the same
thing: a needless fallback and a wrong device action score as one row each, so the
corpus cannot express the difference between them. Anyone judging this plan on the
match column will conclude it is not worth doing. The plan is worth doing because
of the middle two columns.

**Two rows are simulated, two are bounded.** P1 and P2 change a pack field and an
engine condition, so they can be executed exactly. P0 and P4 require a retrain or
a taxonomy change, which cannot be simulated against fixed weights — those rows are
**upper bounds** that assume the retrain achieves its goal and costs nothing
elsewhere. It will cost something. Treat them as ceilings.

**P2 costs five rows, and they are named.** The class-aware guard sends these to
fallback:

```
Ginger mute            -> was Cmd.VolumeMute
mute Michael Jackson   -> was Cmd.VolumeMute
silence Henry          -> was Cmd.VolumeMute
unmute serenity        -> was Cmd.VolumeUnmute
stream iHeartRadio     -> was Cmd.StreamingStart
```

Every one is *"command + a proper noun"* — addressing a mute or a stream by name.
That capability is what P2 trades away for nine fewer false fires. **This is a
product decision, not an engineering one** (§5).

**P5 measures as zero on this corpus** and is still in the plan. §2 P5 explains
why.

**The corpus has no multi-turn traffic.** `PhraseReport` resets the engine before
every phrase, so nothing here sizes slot-filling behaviour. P6 in particular is
floored, not measured.

---

## 2. The work

Each item states **what**, **where** (exact artifact), **how**, the **measured or
bounded effect**, and **how it is verified**.

**M0 comes before all of them.** It is not product work, and it is the only item
whose absence makes every other item unmeasurable.

---

### M0 — fix the measurement, before anything else

**This is not product work and it is not optional. Nothing else in this plan can
be measured until it is done.**

**Finding:** `QADataBasedDecision_Cmd_Reminders_Fallback.md` §5,
`QADataBasedDecision_Help.md` §0/§5 E.

#### Why it comes first

Of the 674 rows the corpus currently scores as misses, roughly **306 are not
failures at all**:

| kind | rows | what it actually is |
|---|---:|---|
| slot answers run standalone | 232 | `5 p.m.`, `take medication`, `go to gym`, `personal`, `crowd` — answers to a follow-up prompt, filed under the intent that was active when they were collected. `PhraseReport` resets the engine before every phrase, so they are asked a question they cannot answer. |
| out-of-scope rows labelled `Help_*` | ~74 | `what is the temperature in International Falls`, `where are the Black Hills located`. The engine correctly refuses them and is marked wrong for it. |

Remove both and **the same code, unchanged, measures 92.4%** instead of 87.4%:

```
reported today        4,729 / 5,403  =  87.4%
measured honestly     4,777 / 5,171  =  92.4%
```

**This is not a five-point improvement and must never be presented as one.** The
product did not change. The number changed because the old one was counting things
that were not broken.

Three consequences follow, and they are the actual argument for doing this first.

1. **The rest of this plan is invisible without it.** P0 + P1 + P2 move 22 rows.
   The corpus carries about 306 rows of noise. Twenty-two rows inside three hundred
   of noise cannot be distinguished from drift — the work would ship and nobody
   could show it helped.
2. **Regressions are equally invisible.** A change that breaks fifteen rows
   disappears into the same noise. There is currently no way to catch one.
3. **It points effort at the wrong work.** A reported 87.4% invites "close the
   12% gap". Half that gap is not a gap. Time spent on
   `what is the temperature in International Falls` is time spent on a row that is
   already correct.

#### What to change

**(a) Separate slot answers from commands.** The 232 rows above depress
`reminders.add` from **89.2% to 51.5%** on their own. Score them in slot-filling
mode — prime the engine with the pending intent before the phrase — rather than
standalone. Keep a copy in the out-of-scope safety sheet, because
`QADataBasedDecision_Cmd_Reminders_Fallback.md` §5.2 shows they carry a real
signal there.

**(b) Re-label the 56 out-of-scope phrases** currently filed under `Help_*` — 68
rows where the engine is right and the label is wrong, 17% of the Help sheet. The
full list is `QADataBasedDecision_Help.md` §7, printed row by row so it can be
disputed rather than taken on trust.

**(c) Add three columns to `PhraseReport.swift`:** `features`, `oov`, and the
keyword rule's own intent when `arbitration == ruleOnly`. Their absence is why
§3.2, §3.3 and §4.1 of the Cmd report all needed an external simulator. The
feature count arrives with P2 anyway.

**(d) Add a bystander sheet** — ordinary English nobody addressed to the device —
scored on "did the device act", not on accuracy. That sheet is the only one that
would have caught `going down` ×7.

**Effect:** no behaviour change on the device. Reported accuracy **87.4% → 92.4%**
on identical code, and — the point — every later measurement in this plan becomes
readable.

**Caveat, stated plainly.** The 92.4% rests on a judgement about which 74 rows are
mislabelled. That judgement is printed in full in the source documents. If rows are
disputed, the number moves; the argument for doing this first does not.

---

### P0 — `down` / `up` particle negatives

**Finding:** `QADataBasedDecision_Cmd_Reminders_Fallback.md` §3.2,
`QADataBasedDecision_SingleTokenCollapse.md` §3.1/§4.

Eleven distinct phrases / 18 rows reach a state-changing volume command on a
particle alone: `going down` ×7, `lying down` ×2, `laying down`, `calm down`,
`winding down`, `too funny`, `pulling up`, `what's up`, `pick up`, `set up`,
`turn mute hearing aids up`.

**Why this is first.** Two measurements, not one:

- `Cmd.VolumeDecrease` scores **469/469** on the command sheet. Every legitimate
  volume-down command in the corpus is already answered correctly.
- **Zero** correct rows in the entire 5,411-row corpus have a feature set of only
  `{down}` or `{up}`. Nothing correct depends on a bare particle being decisive.

So the measured downside risk on this corpus is zero, and the upside is 11 of the
18 rows that P2 cannot reach (P2 catches the 1-feature cases; `going down` ×7 has
two features and an OOV ratio of 0.00, so no guard can ever see it).

**Where:** `IntentClassifier/language_packs/en/train.csv`.

**How:** add SHORT `Default Fallback Intent` rows — `going down`, `lying down`,
`laying down`, `winding down`, `calm down`, `sit down`, `slow down`,
`settle down`, `quiet down`, `keep it down`, `write it down`, `get down`,
`back down`, `speak up`, `hurry up`, `hands up`, `pulling up`, `what's up`,
`pick up`, `set up`.

Length is the point. `down` already appears in 27 fallback rows, but every one is
a long sentence (`ashes to ashes all fall down`, `i was down 17 grand earlier
today`) and none constrains the one- and two-feature region where the failure
lives — `QADataBasedDecision_SingleTokenCollapse.md` §4.1.

**Effect (bounded):** wrong-act −11, false-fire −8, on top of P2.

**Verify:** full `holdout_honest.csv` re-run plus a replay of this corpus.
`Cmd.VolumeDecrease` must still be 469/469 and `Cmd.VolumeIncrease` must not drop
below 583/621.

---

### P1 — the help-marker pattern, both directions

**Finding:** `QADataBasedDecision_VOlumeIncrease.md` §3,
`QADataBasedDecision_Help.md` §3.2, `QADataBasedDecision_Cmd_Reminders_Fallback.md` §3.4.

One pack field carries two opposite defects.

**Under-triggering.** The pattern has `how do i` but not `how do you`, so
`how do you turn the volume up on the hearing aid` **raises the volume** — while
the model itself had answered `Help_Volume` at 0.9559 and was overruled by a
keyword rule.

**Over-triggering.** `(\w+\s+help\b)` matches "can **you help** me set a
reminder", which is a request to *do* something, not to *learn how*. The guard
redirects `reminders.add` (model: **0.9857**) to `Help_Reminder`, the re-read
returns 0.0138, and the user is told the device did not understand.

**Where:** `IntentClassifier/language_packs/en/platform.yaml` →
`help_marker_guard.markers`. No engine change. No retrain.

**How:**
- widen `how\s+(to|do\s+i|does|can\s+i|is|would\s+i)` to include
  `do you`, `do we`, `can you`, `would you`;
- remove or narrow `(\w+\s+help\b)` so it does not capture "<pronoun> help me
  <verb>".

**Effect (simulated, exact):** match +2, wrong-act −1. Each half fixes exactly one
row and breaks none:

```
P1a widen  : how do you turn the volume up…   Cmd.VolumeIncrease -> Help_Volume   (BETTER, 0 worse)
P1b narrow : can you help me set a reminder   fallback           -> reminders.add (BETTER, 0 worse)
```

**Note what P1 does NOT fix.** `how can I add reminder` stays broken. `how can i`
is a legitimate help marker, so the guard is right to fire — the damage is done by
the confidence re-read afterwards. That is §5's open question, not a pattern bug.

**Verify:** `HelpMarkerGuardTests`; full holdout (the pattern touches every paired
command intent); re-run all four phrase reports.

---

### P2 — class-aware degeneracy guard (**VIK-073**)

**Finding:** `QADataBasedDecision_SingleTokenCollapse.md` (whole document),
`QADataBasedDecision_Help.md` §3.5,
`QADataBasedDecision_Cmd_Reminders_Fallback.md` §3.2/§4.1.

The featuriser has no `<unk>` column, so an unknown token is dropped rather than
weighed. `mute swan` and bare `mute` produce the *same* vector, and a one-feature
vector saturates the softmax — so degeneracy produces **high** confidence.
`oov_bypass = 0.97` then stands the OOV guard down precisely on those inputs.

The fix: stand the guard down only when the confidence is high **and** the
utterance carried enough signal for that confidence to mean something — and apply
that tightening **only where the resulting intent is state-changing**.

**Where — this needs five files across three layers:**

| artifact | change |
|---|---|
| `language_packs/en/nlu_schema.json` | per-intent `is_state_changing` flag — no runtime can tell a command from a read-only card today |
| `packages/buildtime/nlu_compiler/content_bundle.py` | emit it into the bundle |
| `VoiceAIKit/.../Pack/Schema/PackSections.swift` | decode it (optional; absent ⇒ today's behaviour) |
| `VoiceAIKit/.../Pack/Loader/PackTFIDFVectorizer.swift` | expose the non-zero feature count — `vectorize(_:)` already computes it as `counts.count` and discards it |
| `VoiceAIKit/.../NLU/Engine/NLUEngine.swift` (the `oovReject`/`oovBypass` block) | `bypass = conf >= oovBypass && (features >= 2 \|\| !isStateChanging(intent))` |

**Effect (simulated, exact):** match **+4**, false-fire **39 → 30**,
wrong-act **92 → 81**. Nine rows better, five worse, one neutral — all sixteen
are listed in §1.3 and in the source document.

Cross-checked against the honest holdout in
`QADataBasedDecision_SingleTokenCollapse.md` §3.5: 1344 (91.43%) / 6 wrong
actions, versus 1346 / 7 for base and 1343 / 6 for a flat (non-class-aware)
variant.

**Verify:** holdout with per-row listing (not just the net); all four phrase
reports; the five named losses must be exactly the five in §1.3 and no others.

**Parity:** Python mirrors the same defect (`engine.py:1285`); Android has no OOV
guard at all (**VIK-059**). **Land P2 before VIK-059**, or Android inherits the
defect along with the feature.

---

### P3 — vocabulary coverage: `timer`, a trigger lexicon, and a build gate

**Finding:** `QADataBasedDecision_Cmd_Reminders_Fallback.md` §4.1/§4.2.

`timer` appears in **zero** rows of `train.csv`. It is not trimmed by `min_df=2`;
it was never there. `alarm` appears 11 times, and the contrast is total:

```
set an alarm   0.9843 -> reminders.add        set a timer   0.6607 -> fallback
```

Because the featuriser drops the word rather than flagging it, the OOV ratio
becomes `1 ÷ (tokens spoken)` — so whether the feature works depends on **how many
words the user says, not what they say**. 8 of 22 realistic phrasings work. Two
fail as wrong actions: `start a timer` → `Cmd.TranscribeStart` 0.9925,
`stop the timer` → `Cmd.StreamingStop` 0.9993.

The vocabulary explains itself: 20 pure-digit unigrams including `1523`, `3334`,
`328`, `148`, `74`; five number words present (`one two three four eleven`) and
25 absent (`five`…`thirty`); 84 of 4,424 bigrams contain a number. Each artefact
cleared `min_df=2` because the `can you X` / `please X` augmentation duplicates
every mined transcript. **The vocabulary is not curated — it is whatever survived
augmentation.** That is one sentence explaining both why `3334` is in and why
`timer` is out.

**Where and how — three parts, in this order:**

1. `language_packs/en/train.csv` — add `timer`, `timers`, `seconds`, `second`
   rows for `reminders.add` plus the 25 missing number words; remove the ASR
   artefacts at source.
2. `language_packs/en/nlu_schema.json` — each intent declares a
   **`trigger_lexicon`**: the surface forms the product promises to understand
   (`reminders.add`: remind, reminder, alarm, **timer**, wake me, ping me…).
   Nothing in the pack records today that "timer" is a way to say "reminder",
   which is exactly why nobody noticed.
3. `packages/buildtime/nlu_compiler` — assert every declared form is present in
   the fitted unigram vocabulary; **fail the build** otherwise.

**Effect:** 3 corpus rows. **The corpus is the wrong measure here** — it contains
7 rows mentioning `timer` in 5,411. The value is part 3: it converts the next
missing capability word from a QA discovery into a build failure.

**Do not ship a keyword rule for `timer` as anything but a stop-gap.** It works
only because `ruleOnly` sets `conf = 1.0`, which trips the P5 bypass and disables
the OOV guard for that turn — it exploits the defect P5 fixes. It is also blunt:
`pause the timer` and `cancel the timer` would route to `reminders.add`. If it
ships, it ships with an expiry note pointing at this section.

**Verify:** full retrain + holdout; the timer phrasing sweep must go from 8/22 to
at least 19/22; `start a timer` and `stop the timer` must no longer fire the wrong
command.

---

### P4 — `Cmd.MemoryChange` versus `Help_ChangingMemories` / `Help_MemoryOptions`

**Finding:** `QADataBasedDecision_Cmd_Reminders_Fallback.md` §4.3,
`QADataBasedDecision_Help.md` §4.3.

`Cmd.MemoryChange` is 518 rows — 22% of the command corpus — at **72%**, the worst
of twelve. Fifty rows (15 distinct phrases) are commands answered with a help
card:

```
change memories          x13  -> Help_ChangingMemories  0.9810
change programs to Cloud  x9  -> Help_ChangingMemories  0.8791
custom                    x5  -> Help_MemoryOptions     0.9931
change programs           x4  -> Help_ChangingMemories  0.9904
```

No marker, no guard, `arbitration` is `-`. **The model itself prefers the help
intent, at 0.98 and above.** It is not uncertain; two intents cover the same
ground. The Help report shows the mirror image — 18 rows where a help question
lands on a different help intent, the largest pair being
`Help_RemoteProgramming` ↔ `Help_DeviceSettings`.

**Where:** `language_packs/en/nlu_schema.json` — intent definitions —
**before any retraining.**

**How:** give the pairs disjoint scopes, merge them, or add a disambiguation turn.
`change programs` genuinely is ambiguous between performing the change and asking
how; a human would ask back.

**Effect (bounded):** match +50 rows. No safety change — a help card is not a
device action.

**This blocks P0 and P3's retrain.** Training two overlapping intents harder
sharpens the boundary without making it correct.

---

### P5 — decouple the OOV guard's trigger from the arbitration confidence

**Finding:** `QADataBasedDecision_Cmd_Reminders_Fallback.md` §3.3 — from code, not
from data.

`PackClassifierAdapter` sets `ruleOnlyConfidence = 1.0`. `NLUEngine` gates the OOV
guard on `conf < oovBypass` with `oovBypass = 0.97`. **A `ruleOnly` turn therefore
disables the OOV guard**, however much of the utterance the featuriser could not
represent. Two safety mechanisms wired so one silently switches the other off.

**Measured effect on this corpus: zero.** `ruleOnly` fires twice in 2,381 command
rows and zero times in 2,197 out-of-scope rows.

**It stays in the plan anyway**, for three reasons: it is the mechanism P3's
stop-gap would ride on; the corpus contains almost no `ruleOnly` traffic and
therefore cannot size it; and a latent defect that costs nothing to fix while the
surrounding code is already open is cheaper now than after the next rule is added.

**Where:** `NLUEngine.swift` (the guard condition) and `PackEngineFactory.swift`.

**How:** test the model's confidence in the **returned** intent rather than the
arbitration verdict's synthetic `1.0`. `IntentResult.breakdown.stage2` already
carries the distribution, so no new plumbing.

**Verify:** holdout must be unchanged (it is, in simulation); add a unit test that
a `ruleOnly` turn with a high OOV ratio is still refused.

---

### P6 — cancel cues (**VIK-068**)

**Finding:** `QADataBasedDecision_Cmd_Reminders_Fallback.md` §4.4.

```
cancel last reminder   reminders.complete  0.6933 -> fallback
quit reminder          reminders.add       0.6058 -> fallback
cancel the reminder    Help_Reminder       0.5473 -> fallback
```

There is no exit from a slot flow except exhausting `max_slot_attempts`.

**Where:** `platform.yaml` (`cancel_cues`) + `NLUEngine.handleSlotFilling`,
mirroring the Python reference's `cancel_cues` / `_is_cancel` at
`engine.py:242-244, 862+`, **including the purity guard** so "no, tomorrow at 5"
reads as a correction rather than a cancellation.

**Effect:** 5 corpus rows — a floor, not a measurement. The corpus has no
multi-turn traffic, and `nevermind` ×9 and `cancel` ×3 sit in it labelled
out-of-scope, which is correct standalone and wrong mid-flow. This item cannot be
sized without a multi-turn corpus (M0).

---

### P8 — keyword rule hygiene

**Finding:** `QADataBasedDecision_VOlumeIncrease.md` §4.

`Cmd.VolumeIncrease` ships nine rules. Over 5,411 rows, **rule #9 matches 593 and
the other eight match one row between them.** That one match is rule #10
(`\b(too|so|very|really)\s+(quiet|low|soft|faint)\b`) firing on
`how to step too low` — a false claim that lands on fallback only because the help
guard caught it.

**How:**
1. **Fix #10** — narrow `too low` to the audio context the way #11 already does,
   or fold it into #11 and delete it.
2. **Do not delete #11–#17 on this evidence.** They encode empathetic phrasings
   ("everything sounds so faint") that this corpus contains none of. Get the
   evidence first — a corpus that contains them, or product confirmation that they
   shipped.
3. **Record the finding either way**, before anyone adds a tenth rule.

Related, from `QADataBasedDecision_Help.md` §3.4: across 400 `Help_*` rows the
keyword layer contributes **zero** correct answers the model did not already have,
and causes one wrong action. That is Help traffic only — on command traffic rules
hit 1,307 of 2,381 rows and agree with the model 1,303 times — but it is why P8
is hygiene rather than expansion.

---

### Architecture track — delexicalise slot spans before featurisation (**VIK-056, widened**)

Not a numbered priority. It is larger than anything above and must not be
sequenced against them.

P3 shows the model needing `two minutes` for **arithmetic** reasons rather than
semantic ones: the OOV ratio is `unknown ÷ total`, so adding known words dilutes
it. The pack already declares `sys.date-time` and `sys.number-integer` as dynamic
entities and `memory` (38), `recurrence` (14), `remind` (6) as closed enums — but
the resolver runs **after** classification.

Running it **before**, and replacing matched spans with placeholders in both
training and inference, would collapse `for two minutes` / `for 15 minutes` /
`for 30 seconds` into one vector, remove the 20 digit unigrams and 84 numeric
bigrams from the vocabulary, and stop the OOV ratio counting values it was never
meant to judge.

**Shape:** a `runtime/normalization.json` spec shipped **in the pack**, applied by
the trainer before fitting and by every runtime before `vectorize`. One spec, so
the three runtimes are identical by construction — the lesson of VIK-050, VIK-055
and VIK-070. Raw text still reaches the slot resolver; delexicalisation is for
classification only.

**Measured limit, so it is not oversold.** Of the 79 corpus rows that depend on
`oov_bypass`: **48 are other unknown words, 29 are proper nouns, 2 are
number/time**. Delexicalisation removes the number/time class and nothing else.
Proper nouns — the five rows P2 costs — need P2. **The two are complementary, not
alternatives.**

Keep it as **one** ticket with VIK-056's contraction work. Two tickets would
produce two transform chains, which is exactly how the runtimes have diverged
before.

---

## 3. Sequencing and landing rules

| step | items | why grouped / separated |
|---|---|---|
| **0** | **M0 (measurement)**, P4 (taxonomy), P3.2–P3.3 (lexicon + build gate) | no model change, no risk. M0 is a hard prerequisite: without it none of steps 1–5 can be shown to have worked |
| **1** | P1 (marker), P8.1 (rule #10) | pack fields only, no retrain; ship together, one holdout run |
| **2** | P0 + P3.1 (training data) | one retrain, one full holdout; P4 must be settled first |
| **3** | P2 (VIK-073) | **alone** — its own holdout with a per-row listing |
| **4** | P5 | **alone** — it changes which turns the guard inspects |
| **5** | P6 | needs a multi-turn corpus to size; independent of the decision path |
| **—** | architecture track | its own plan, its own measurement, after step 4 |

**Three landing rules, all of them learned the hard way:**

1. **Steps 3, 4 and the architecture track never land together.** VIK-055 is the
   precedent: a net accuracy figure concealed a −10 that a three-way split reduced
   to −1, and only the per-row listing revealed it.
2. **Every engine change lands with its measurement in the commit message**,
   including the rows it moves. P2 is accuracy-positive here but was
   accuracy-negative in its flat form; a future reader without the numbers will
   revert it. This is what `scripts/analysis/arbitration_holdout.py` exists to
   prevent, and it only works if the numbers are written down.
3. **Pack content and model artifacts change in separate releases.** Changing the
   guard pattern and the vocabulary in one pack makes any delta unattributable.

---

## 4. What must not be done

- **Do not lower `confidence` (0.70)** to rescue `what is smart assistant`
  (0.6539) or `set a timer for two minutes` (0.7351, a 0.035 margin). It is shared
  by every intent; the phrases below it include `going down`.
- **Do not raise `oov_reject` (0.25) or lower `oov_bypass` (0.97).** Measured: the
  OOV guard prevents 9 state-changing wrong actions and costs 18 correct answers —
  accuracy-negative, safety-positive. Lowering `oov_bypass` to 0.90 buys +2
  accuracy on the holdout and zero safety. The *condition* is wrong, not the
  number; that is P2.
- **Do not hand-edit `pack-en-v1.0.54`.** It is signed. Everything goes through
  the compiler.
- **Do not "fix" `how do I clean my chair` → `Help_CleanCare`.** The question form
  carries seven features on its own and the object is noise. Cost is one back
  press, and tightening it would break `how do I clean my hearing aids` ×11.
- **Do not delete keyword rules #11–#17** on the evidence in this plan (P8).
- **Do not treat the match column as the success metric** (§1.3).

---

## 5. Decisions needed from product, not engineering

These are in the plan because engineering cannot settle them and each one blocks
or shapes an item above.

1. **P2's five lost rows.** Is *"mute Michael Jackson"* / *"silence Henry"* —
   addressing a mute or stream by a name — a capability the product keeps? If yes,
   P2 needs the narrower variant (§1.3) and that variant is **unmeasured**.
2. **The guarded-redirect fire bar.** `how can I add reminder` (model 0.9173) and
   `how do I turn off my hearing aids` (×3) are correctly identified as help asks
   and then discarded by the confidence re-read — 9 rows across two reports. The
   source comment at `NLUEngine.swift:558` records this as deliberate ("deflected
   11 of 12 guarded turns to the fallback"). A redirect replaces a command with a
   read-only card, so it is strictly safer than what it replaced. Should it clear
   the same 0.70 bar? The holdout **cannot** score the benefit, so this must be
   decided on the cost model.
3. **`Cmd.MemoryChange` vs the two memory help intents** (P4) — merge, disjoin, or
   disambiguate.
4. **Bare `volume` ×19** (`QADataBasedDecision_VOlumeIncrease.md` §1 Group B) —
   `Help_Volume` card, fallback, or `Cmd.VolumeIncrease`? All three are
   defensible; only one can ship.
5. **Absolute-volume phrasings** (`set volume to 50`, 7 phrases / 9 rows, same
   document Group C) — a taxonomy gap, not a defect. In or out of scope?

---

## 6. Traceability — every finding, and where it lands

| finding | source | item |
|---|---|---|
| Stage 0 keyword bypass overrules the model | VIK-055 plan | **shipped** (three-way arbitration) |
| Help guard misses `how do you` | VolIncr §3, Help §3.2, Cmd §3.4 | **P1** |
| `\w+\s+help\b` over-triggers | Cmd §3.4 | **P1** |
| Guarded redirect discarded by the re-read | Help §3.3, Cmd §3.4 | **§5 decision 2** |
| Single-token collapse / `oov_bypass` exemption | Collapse (whole), Help §3.5, Cmd §3.2 | **P2** |
| `down`/`up` particles fire volume commands | Collapse §3.1, Cmd §3.2 | **P0** (+P2 for the 1-feature half) |
| `producesNoFeatures` has no caller | Collapse §7 | **P2** (wire it or delete it, same file) |
| `ruleOnly` conf 1.0 disables the OOV guard | Cmd §3.3 | **P5** |
| `timer` absent from the vocabulary | Cmd §4.1 | **P3.1** |
| Vocabulary is uncurated (`3334` in, `timer` out) | Cmd §4.2 | **P3.2 + P3.3** |
| Model needs `x minutes` for arithmetic reasons | Cmd §4.1 | **architecture track** |
| `Cmd.MemoryChange` ↔ memory help intents | Cmd §4.3, Help §4.3 | **P4** |
| `Help_RemoteProgramming` ↔ `Help_DeviceSettings` | Help §4.3 | **P4** (same class) |
| `what is smart assistant` ×12 at 0.6539 | Help §4.1 | **P0's retrain** (training data) |
| Audiologist family, 13 rows | Help §4.2 | **P0's retrain** |
| No cancel cue | Cmd §4.4 | **P6** |
| 8 of 9 `Cmd.VolumeIncrease` rules never fire; #10 is a false claim | VolIncr §4 | **P8** |
| Keyword layer net-negative on `Help_*` traffic | Help §3.4 | **P8** (recorded, not actioned) |
| `reminders.add` 51.5% is a harness artifact | Cmd §5.1 | **M0a** |
| 68 Help rows mislabelled out-of-scope | Help §0 | **M0b** |
| Report lacks `features` / `oov` / rule intent | Collapse §9, Help §5 E, Cmd §6 P7 (now M0) | **M0c** |
| Bare `volume` ×19 ambiguous | VolIncr §1 Group B | **§5 decision 5** |
| Absolute-volume taxonomy gap | VolIncr §1 Group C | **§5 decision 6** |
| Android has no OOV guard | Android doc VIK-059 | after **P2** — never before |
| iOS runs a third arbitration variant on purpose | Android doc VIK-072 | debt, tracked, no action here |
| `contestedConfidence` is a code constant ×3 | Android doc VIK-070 | unchanged; independent of this plan |
| Slot answers scored standalone | Cmd §5, Help — | **M0a** |
| `how do I clean my chair` → CleanCare | Help §3.5 | **deliberately not actioned** (§4) |
| Ambiguous fragments (`connect`, `status`, `Telecare`) | Help §4.4 | **deliberately not actioned** — fallback is correct |

---

## 7. Method, reproduction, caveats

**Simulator.** Full head weights + `temperature_coreml_full` + the iOS unigram
vocabulary, replaying the shipped ladder: arbitration → help redirect → OOV guard →
fire test. Validated twice — against device output for every miss in the
`Cmd.VolumeMute` report, and against a live device log for
`Set a timer for two minutes.` (predicted 0.7351, device logged `conf=0.735064`).

**Corpus.** `VoiceAIKit/Tests/VoiceAIKitTests/Fixtures/help_intent_phrases.json`,
5,411 rows / 1,844 distinct phrases. **Holdout:**
`IntentClassifier/language_packs/en/holdout_honest.csv`, n=1470 — the same corpus
the VIK-055 measurement used, so figures are comparable across all these documents.

**Caveats.**

- P0 and P4's figures are **upper bounds**, not measurements. Fixed weights cannot
  simulate a retrain.
- P1 and P2's figures are exact for this corpus and this pack only.
- P5 measures zero here because the corpus has almost no `ruleOnly` traffic — that
  is a limit of the corpus, not evidence that the defect is harmless.
- P6 cannot be sized at all from this corpus: `PhraseReport` resets the engine
  before every phrase, so no multi-turn behaviour is exercised.
- Corpus labels are evidence, not truth. Every judgement call in the source
  documents prints its underlying list so it can be disputed row by row.
