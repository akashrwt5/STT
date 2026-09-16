# QA data-based decision — `Cmd.*`, `reminders.*` and the out-of-scope corpus

**Inputs** — four phrase reports produced by
`VoiceAIKit/Tests/VoiceAIKitTests/PhraseReport.swift` against `pack-en-v1.0.54`
on branch `…-Porting-Python-logic-VIK-055-keyword-arbitration`:

| file | scope | distinct | rows |
|---|---|---:|---:|
| `phrase-report-Cmd--.tsv` | 12 `Cmd.*` intents | 386 | 2,381 |
| `phrase-report-reminders-add.tsv` | `reminders.add` | 199 | 373 |
| `phrase-report-reminders-complete.tsv` | `reminders.complete` | 20 | 52 |
| `phrase-report-other--reminders----fallback-.tsv` | out-of-scope + both reminder intents | 1,253 | 2,622 |

**Scope of this document — read this first.** Everything here describes the
**VoiceAIKit package** — `VoiceAIKit/Sources/VoiceAIKit/…` — which is what
`PhraseReport` exercises and what the `decide` / `oov_guard` log lines come from.
No statement in this document is about any other code path.

Companion documents: [`QADataBasedDecision_Help.md`](./QADataBasedDecision_Help.md),
[`QADataBasedDecision_VOlumeIncrease.md`](./QADataBasedDecision_VOlumeIncrease.md),
[`QADataBasedDecision_SingleTokenCollapse.md`](./QADataBasedDecision_SingleTokenCollapse.md).

**Method.** Counts come from the TSVs. Feature counts, OOV ratios and vocabulary
membership come from an iOS-faithful simulator (full head weights,
`temperature_coreml_full`, the iOS unigram vocabulary), which was validated twice:
against the device output for every miss in the `Cmd.VolumeMute` report, and again
against a live device log for `Set a timer for two minutes.` — predicted 0.7351,
device logged `conf=0.735064`. Where a number required judgement rather than
measurement, the judgement is named and the underlying list is printed.

---

## 1. Headline

Deduplicated across all four reports: **1,850 distinct phrases / 5,403 rows.**

| slice | rows | result |
|---|---:|---|
| `Cmd.*` | 2,381 | **90.8%** matched |
| out-of-scope (`Default Fallback Intent`) | 2,197 | **94.6%** correctly refused |
| `reminders.*` | 425 | 55.5% matched — real figure **89.2%**, see §5 |
| `Help_*` (companion doc) | 400 | 64.5% raw / 81.5% adjusted |
| **whole corpus** | **5,403** | **87.5%** |

**The number that matters most:**

> **92 rows (1.70%) reach a state-changing command the QA label did not ask for.**

| intent fired | rows |
|---|---:|
| Cmd.MemoryChange | 18 |
| Cmd.VolumeDecrease | 14 |
| Cmd.VolumeMute | 9 |
| Cmd.VolumeUnmute | 9 |
| Cmd.SendMessage | 8 |
| Cmd.VolumeIncrease | 7 |
| Cmd.StreamingStop | 6 |
| Cmd.StreamingStart | 6 |
| reminders.add | 5 |
| Cmd.TranscribeStart | 4 |
| reminders.complete | 3 |
| Cmd.ListenMessage | 2 |
| Cmd.FindMyPhone | 1 |

---

## 2. What is working — do not disturb these

### 2.1 Out-of-scope refusal is strong

2,197 rows the QA corpus labels out of scope:

```
correctly refused  2,078 rows  (94.6%)
fired something      119 rows  ( 5.4%)
   state-changing     39 rows
   read-only          29 rows
   Help_* card        51 rows
```

The command classifier is not trigger-happy in general. The 39 rows are §3.1.

### 2.2 VIK-055 arbitration is behaving, and rules stay out of the way

Keyword-rule participation, measured per sheet:

| sheet | rows hitting a rule | corroborated | ruleOnly | contested |
|---|---:|---:|---:|---:|
| `Cmd.*` | 1,307 of 2,381 (55%) | 1,303 | 2 | 2 |
| out-of-scope | 7 of 2,197 (0.3%) | 5 | 0 | 2 |
| `reminders.*` | 129 of 425 | 129 | 0 | 0 |

Two things to read here.

**Rules and the model agree almost always.** On command traffic 1,303 of 1,307
rule hits are `corroborated`. `ruleOnly` — the branch where the rule overrules an
in-scope model answer — fires twice in 2,381 rows.

**Rules barely touch out-of-scope traffic**: 7 rows in 2,197, and 4 of those are
`send a message to Daniel` / `send Daniel a message`, which are real send-message
commands the QA corpus mislabels.

**All six `contested` rows across every sheet land on fallback**, which is what
VIK-055 shipped to do:

```
I'm surprised that wasn't part of the setup I gues…  [Cmd.VolumeIncrease] -> fallback 0.600
listings of silence come on                          [Cmd.VolumeMute]     -> fallback 0.600
it sticks up I mean it just feels like there's way…  [fallback]           -> fallback 0.600
sorry to trouble you thank you so much               [fallback]           -> fallback 0.600
who is the PM of create reminder                     [Help_Reminder]      -> fallback 0.600
(+ one in the Help report)
```

### 2.3 Four intents are effectively solved

| intent | rows | match |
|---|---:|---:|
| Cmd.VolumeDecrease | 469 | **100%** |
| Cmd.VolumeUnmute | 62 | **100%** |
| Cmd.StreamingStop | 157 | 99% |
| Cmd.StreamingStart | 193 | 96% |

`Cmd.VolumeDecrease` at 469/469 is load-bearing for §3.2 — remember it.

---

## 3. What is broken — engine-side

### 3.1 Thirty-nine out-of-scope rows change device state

The full list, by volume:

| phrase | rows | fires | conf |
|---|---:|---|---:|
| going down | **7** | Cmd.VolumeDecrease | 0.8785 |
| use my hearing aids | 3 | Cmd.StreamingStart | 0.7545 |
| lying down | 2 | Cmd.VolumeDecrease | 0.9998 |
| send a message to Daniel | 2 | Cmd.SendMessage | 1.0000 |
| send Daniel a message | 2 | Cmd.SendMessage | 1.0000 |
| stop it | 2 | Cmd.StreamingStop | 0.9691 |
| again | 1 | Cmd.VolumeUnmute | 0.9920 |
| all right now I got super hearing | 1 | Cmd.VolumeMute | 0.8839 |
| at 4 p.m. central Time I want an alarm | 1 | reminders.add | 0.9795 |
| calm down | 1 | Cmd.VolumeDecrease | 0.9998 |
| complete | 1 | reminders.complete | 0.9994 |
| I would eat at this table | 1 | reminders.add | 0.8097 |
| laying down | 1 | Cmd.VolumeDecrease | 0.9998 |
| pulling up | 1 | Cmd.VolumeIncrease | 0.9996 |
| set a timer for me to go to the grocery store | 1 | reminders.add | 0.9174 |
| start dreaming | 1 | Cmd.TranscribeStart | 0.9925 |
| start reading | 1 | Cmd.TranscribeStart | 0.8213 |
| stop | 1 | Cmd.StreamingStop | 0.9990 |
| stop beeping | 1 | Cmd.StreamingStop | 0.9990 |
| stop. | 1 | Cmd.StreamingStop | 0.9990 |
| the microphone | 1 | Cmd.StreamingStart | 0.9475 |
| this is a test message testing 1 2 3 | 1 | Cmd.SendMessage | 0.8519 |
| tomorrow | 1 | reminders.add | 0.9598 |
| too funny | 1 | Cmd.VolumeDecrease | 0.9823 |
| turn on hearing aid maintenance | 1 | Cmd.VolumeUnmute | 0.9979 |
| what's up | 1 | Cmd.VolumeIncrease | 0.9820 |
| winding down | 1 | Cmd.VolumeDecrease | 0.9998 |

**Not all of these are engine errors, and the document should not pretend they
are.** `send a message to Daniel` ×2, `send Daniel a message` ×2,
`at 4 p.m. central Time I want an alarm` and
`set a timer for me to go to the grocery store` are real commands that the corpus
labels out of scope — 6 rows where the engine is right. `stop` / `stop.` /
`stop it` are genuinely ambiguous out of context: if streaming is running,
`Cmd.StreamingStop` is the correct answer.

Stripping those leaves roughly **28 rows** that are plainly wrong, and §3.2 is
where most of them come from.

### 3.2 One particle family is 20% of every wrong action in the corpus

| phrase | rows | fires |
|---|---:|---|
| going down | 7 | Cmd.VolumeDecrease |
| lying down | 2 | Cmd.VolumeDecrease |
| laying down / calm down / winding down | 3 | Cmd.VolumeDecrease |
| too funny | 1 | Cmd.VolumeDecrease |
| pulling up / what's up | 2 | Cmd.VolumeIncrease |
| pick up / set up (`reminders.add` sheet) | 2 | Cmd.VolumeIncrease |
| turn mute hearing aids up (`Cmd.VolumeMute` sheet) | 1 | Cmd.VolumeIncrease |

**11 distinct phrases / 18 rows = 20% of the 92.**

The mechanism is documented in
[`QADataBasedDecision_SingleTokenCollapse.md`](./QADataBasedDecision_SingleTokenCollapse.md):
the featuriser drops every out-of-vocabulary token, so a phrase whose only known
word is `down` produces the same vector as `down` alone, and a one-feature vector
saturates the softmax.

**What this report adds is the thing that doc could not supply.** Its §3.1 said
plainly that its 18 hand-picked phrases were *"an existence proof, not a rate."*
This is the rate, on QA-labelled data nobody chose for the purpose — and it comes
with the decisive fact:

> **`Cmd.VolumeDecrease` scores 469/469 on the command sheet.**

Every legitimate volume-down command in the corpus is answered correctly. So
constraining `down` has **no measured cost on the command side**, and the entire
cost of the current behaviour falls on out-of-scope traffic. That asymmetry was
argued for in the collapse document; here it is measured.

### 3.3 A keyword-rule match silently switches the OOV guard off

Structural, found in code, not inferred from data.

`PackEngineFactory.swift` → `PackClassifierAdapter` sets
`ruleOnlyConfidence = 1.0` for the `ruleOnly` branch.
`NLUEngine.swift:663` gates the OOV guard on:

```swift
if let reject = oovReject, let bypass = oovBypass, !outOfScope, conf < bypass {
```

`oov_bypass` is `0.97`. A `ruleOnly` turn therefore arrives with `conf == 1.0`,
`conf < bypass` is false, and **the OOV guard never runs for that turn** — no
matter how much of the utterance the featuriser could not represent.

Two safety mechanisms are wired so that one turns the other off. Neither was
designed to do that; it falls out of using one `conf` variable for the arbitration
verdict and for the guard's trigger.

On this corpus the blast radius is small — `ruleOnly` fires twice in 2,381 command
rows and zero times in 2,197 out-of-scope rows — so **this is a latent defect, not
an active one**. It matters because it is the mechanism any "just add a keyword
rule" fix would ride on. See §6 P1 and §6 P4.

### 3.4 The help-marker guard destroys two unambiguous reminder requests

`QADataBasedDecision_Help.md` §3.3 records this defect with 7 rows. The reminders
report supplies the two clearest cases in the whole corpus:

| phrase | model says | guard re-read | user gets |
|---|---:|---:|---|
| `can you help me set a reminder` | **reminders.add 0.9857** | 0.0138 | "not understood" |
| `how can I add reminder` | reminders.add 0.9173 | 0.0475 | "not understood" |

Both are explicit requests to create a reminder. The model names the right intent
at 0.99 and 0.92. `helpRedirect` rewrites the intent to `Help_Reminder`,
`calibratedConfidence(for:)` re-reads the confidence for *that* intent, and the
result cannot clear the fire bar.

**And these two expose a second defect in the same regex.** The marker pattern
contains:

```
(\w+\s+help\b)
```

which matches "**can you help** me set a reminder". But that phrase is a request
*to perform an action*, not a request *to learn how*. So the same pattern is

- **under-triggering** — `how do you` is absent (`Help` doc §3.2), and
- **over-triggering** — `\w+\s+help\b` captures "can you help me do X".

Both directions produce a wrong answer, and both live in one pack field.

### 3.5 The OOV guard: nine saves, eighteen losses

Measured by replaying all 5,411 corpus rows with and without the guard:

```
state-changing wrong actions prevented :  9 rows
correct answers lost to the guard      : 18 rows
```

Prevented, in full: `turn off the oven` → `Cmd.VolumeMute`,
`go to gym with Vinay tilwani` → `Cmd.MemoryChange`,
`transmemory too personal` → `Cmd.VolumeDecrease`,
`this one makes me want to die` → `reminders.add`,
`nicely done` and `that's awesome` → `reminders.complete`,
`I'm leaving today at 1` and `at 4 p.m. Central Time` → `reminders.add`,
`arms turned off` → `Cmd.VolumeMute`.

Lost, notable: `set a timer for 2 hours` → `reminders.add`,
`dispense last reminder` → `reminders.complete`,
`battery lasting` → `Cmd.BatteryLevel`, `hot tub mute` → `Cmd.VolumeMute`.

**The guard is accuracy-negative and safety-positive**, which is the same trade
recorded elsewhere in this family of documents. Several of the 18 "losses" are
rows where the QA label is itself doubtful (`is President Biden in good health` →
`Help_Health` is not a correct answer), so the real loss is smaller than 18 — but
the sign does not change.

This is the counterweight to any proposal to relax `oov_reject`. It is doing work
that nothing else in the ladder does.

---

## 4. What is broken — content-side

### 4.1 `timer` does not exist in the model

Verified in `language_packs/en/train.csv`:

```
rows containing 'timer'   : 0
rows containing 'timers'  : 0
rows containing 'seconds' : 0
rows containing 'second'  : 0
rows containing 'alarm'   : 11   (9 reminders.add, 2 Default Fallback Intent)
```

`timer` is not trimmed by `min_df=2` — it was never in the data. `alarm` was, and
the contrast is total:

```
set an alarm                    0.9843  -> reminders.add
set an alarm for two minutes    0.9949  -> reminders.add
set an alarm for 8 a.m.         0.9945  -> reminders.add

set a timer                     0.6607  -> Default Fallback Intent
```

Because the featuriser drops the word rather than flagging it, `timer` is always
counted as the one unknown token, and the OOV ratio becomes `1 ÷ (tokens spoken)`.
**Whether the feature works therefore depends on how many other words the user
says, not on what they say:**

| utterance | tokens | oov | conf | result |
|---|---:|---:|---:|---|
| set a timer | 2 | 0.50 | 0.6607 | ❌ OOV **and** below bar |
| set a timer for **2** minutes | 4 | 0.25 | 0.8716 | ❌ blocked on the boundary |
| set a timer for **two** minutes | 5 | 0.20 | 0.7351 | ✅ |
| set a timer for **three** minutes | 5 | 0.20 | 0.6588 | ❌ below bar |
| set a timer for **four** minutes | 5 | 0.20 | 0.7420 | ✅ |
| set a timer for **five** minutes | 5 | 0.40 | 0.9617 | ❌ `five` also unknown |
| set a timer for **15** minutes | 5 | 0.20 | 0.9478 | ✅ |
| set a timer for **20** minutes | 5 | 0.40 | 0.9617 | ❌ `20` unknown |
| set a timer for **30** minutes | 5 | 0.20 | 0.8268 | ✅ |
| set a timer for 30 **seconds** | 5 | 0.40 | 0.8270 | ❌ `seconds` unknown |
| set a timer for one hour | 5 | 0.20 | 0.5120 | ❌ below bar |
| **can you** set a timer for two minutes | 7 | 0.14 | 0.5908 | ❌ below bar |
| timer for two minutes | 4 | 0.25 | 0.4640 | ❌ |

`2` versus `15` is not a rounding detail — the tokeniser is sklearn's
`\b\w\w+\b`, which **drops one-character tokens**:

```
"set a timer for 2  minutes" -> ['set','timer','for','minutes']         4 tokens
"set a timer for 15 minutes" -> ['set','timer','for','15','minutes']    5 tokens
```

**Of 22 realistic timer and alarm phrasings, 8 reach `reminders.add`. All three
`alarm` phrasings work; 5 of 19 `timer` phrasings do.**

Two of the failures are not fallbacks but wrong actions:

```
start a timer   -> Cmd.TranscribeStart  0.9925    (starts transcription)
stop the timer  -> Cmd.StreamingStop    0.9993    (stops streaming)
```

Both are the §3.2 mechanism: `timer` is invisible, the surviving verb decides
alone, the confidence saturates, and `oov_bypass = 0.97` stands the guard down
precisely because it saturated.

### 4.2 Vocabulary audit

```
unigram vocabulary            : 1,472
full vocabulary (with bigrams): 5,896
vectoriser                    : ngram_range=(1,2), min_df=2, sublinear_tf
```

**Pure-digit unigrams (20):**
`00 10 11 12 15 17 30 35 40 50 74 80 90 100 148 200 328 800 1523 3334`

**Number words present (5):** `one two three four eleven`
**Number words absent (25):** `five six seven eight nine ten twelve thirteen
fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty
sixty seventy eighty ninety hundred half quarter`

**Duration units present:** `min minute minutes hour hours day days week month year`
**Absent:** `mins second seconds weeks months years`

**84 of the 4,424 bigrams contain a number** — `10 30`, `11 oclock`, `12 on`,
`100 volume`.

`1523`, `3334`, `328`, `148` and `74` each cleared `min_df=2`, which means each
appeared in at least two training documents. The augmentation that generates
`can you X` / `please X` variants duplicates every mined transcript, so a single
ASR artefact reaches the threshold on its own. **The vocabulary is not curated; it
is whatever survived the augmentation.** That is the same reason `timer` is absent
and `3334` is present.

### 4.3 `Cmd.MemoryChange` is the weakest intent in the corpus

| intent | hit | rows | % |
|---|---:|---:|---:|
| **Cmd.MemoryChange** | **371** | **518** | **72%** |
| Cmd.ListenMessage | 16 | 19 | 84% |
| Cmd.BatteryLevel | 40 | 44 | 91% |
| Cmd.FindMyPhone | 123 | 133 | 92% |
| Cmd.SendMessage | 14 | 15 | 93% |
| Cmd.VolumeIncrease | 583 | 621 | 94% |
| Cmd.VolumeMute | 137 | 145 | 94% |
| Cmd.StreamingStart | 186 | 193 | 96% |
| Cmd.StreamingStop | 155 | 157 | 99% |
| Cmd.ActivityStep | 5 | 5 | 100% |
| Cmd.VolumeDecrease | 469 | 469 | 100% |
| Cmd.VolumeUnmute | 62 | 62 | 100% |

518 rows is 22% of the command corpus and it carries the whole deficit. Three
separable problems.

**(a) The command is answered with a help card — 50 rows.**

| phrase | rows | gives | conf |
|---|---:|---|---:|
| change memories | 13 | Help_ChangingMemories | 0.9810 |
| change programs to Cloud | 9 | Help_ChangingMemories | 0.8791 |
| custom | 5 | Help_MemoryOptions | 0.9931 |
| change Memories restaurant | 4 | Help_ChangingMemories | 0.8434 |
| change programs | 4 | Help_ChangingMemories | 0.9904 |
| change to custom memory | 3 | Help_MemoryOptions | 0.7113 |
| switch to custom memory | 3 | Help_MemoryOptions | 0.7805 |
| change programs to music | 2 | Help_ChangingMemories | 0.9669 |
| (+7 more, 1 row each) | 7 | — | — |

No help marker is present in any of these and no guard is involved — the
`arbitration` column is `-` and the final confidence equals the model confidence.
**The model itself prefers the help intent**, at 0.98 and above. It is not
uncertain; it is confidently choosing an intent that covers the same ground.

This answers the question `QADataBasedDecision_Help.md` §F.16 left open — whether
`Cmd.*` ↔ `Help_*` confusion runs in the reverse direction too. It does:
**23 distinct phrases / 77 rows across the command sheet, and 50 of those 77 rows
(15 distinct phrases) are this one intent.**

**(b) Bare memory names go to fallback.** `personal` ×11, `meeting` ×6, `crowd`
×5, `music` ×5, `television` ×5, `outdoors` ×4, `Auditorium` ×3, `restaurant` ×2.
These are values of the `memory` entity (38 closed values in
`entities/shared/content.json`), labelled as commands. See §5.

**(c) Eighteen wrong state-changing rows** — `change mute` ×4 →
`Cmd.VolumeMute`, `mute` ×2 → `Cmd.VolumeMute`, `decrease volume` →
`Cmd.VolumeDecrease`, `setting stream` → `Cmd.StreamingStart`, and similar. These
are phrases the corpus files under `Cmd.MemoryChange` that read as other commands;
several are QA-labelling artefacts rather than engine errors.

### 4.4 There is no way to cancel a reminder

```
cancel last reminder   model=reminders.complete   0.6933  -> fallback
quit reminder          model=reminders.add        0.6058  -> fallback
cancel the reminder    model=Help_Reminder        0.5473  -> fallback
```

All three land below the 0.70 bar. This is the iOS side of **VIK-068** (no cancel
cue), already recorded in `things-to-pull-from-android.md` §2 against the Python
reference's `cancel_cues` / `_is_cancel`. This report is the first QA evidence for
it.

Two further reminder rows are wrong actions:

```
turn on intelligent reminder   x3  -> Cmd.VolumeUnmute    0.7941
this reminder                  x1  -> reminders.complete  0.9360
```

The first tries to enable a reminder setting and unmutes the device. The second
completes a reminder on a two-word fragment.

---

## 5. What is a measurement artifact, not a defect

### 5.1 `reminders.add` is 89.2%, not 51.5%

Split the 199 phrases by whether they contain a reminder word at all:

| group | distinct | rows | match |
|---|---:|---:|---:|
| contains `remind` / `reminder` / `timer` / `alarm` | 83 | 186 | **89.2%** |
| contains none of them | 116 | 187 | **13.9%** |

The second group is `5 p.m.`, `15 minutes`, `take medication`, `drink water`,
`go to gym`, `tomorrow morning`, `in 5 minutes`, `Seafood`. **These are not
commands.** They are answers to the follow-up prompt, collected inside the reminder
flow and filed under the intent that was active at the time.

`PhraseReport.swift` calls `await engine.reset()` before every phrase, so each one
runs as a fresh single-turn utterance with no pending slot. In that mode a slot
answer cannot succeed and should not be expected to.

**The engine is not failing these rows; the harness is asking them the wrong
question.** The same applies to §4.3(b) — the bare memory names — and to the
`Cmd.SendMessage` yes/no rows `PhraseReport` already skips as dialogue acts.

### 5.2 But the same rows carry a separate, real signal

Run standalone, 32 of the 116 slot-answer phrases still reach an intent:

```
go to gym                 x17  -> Cmd.MemoryChange      0.8160   state-changing
tomorrow morning 5 a.m.    x9  -> reminders.add         0.8389   state-changing
go for a walk              x6  -> Cmd.ActivityWalk      0.9999   read-only
take out the trash         x3  -> Help_InsertDevice     0.9792   help card
tomorrow                   x3  -> reminders.add         0.9598   state-changing
…
```

Inside the flow these are harmless: `NLUEngine.swift:388-432` gates the VIK-038
topic-switch probe on the awaited slot's kind, and the reminder subject and
date-time slots are open, so no probe runs and the utterance is captured as the
slot value. **Outside the flow they act.** That is the out-of-scope precision
question of §3.1 wearing a different label, and it is why these rows are worth
keeping in a corpus even though they should not be scored as `reminders.add`.

---

## 6. Priority — what to fix, in what order, and how

Ordered by (harm × volume) ÷ effort. Each item names the artifact to change, so
the work can be split across the pack, the trainer and the runtime.

### P0 — `down` / `up` negatives in the training data

**Why first.** 18 rows, 20% of every wrong action in the corpus, and
`Cmd.VolumeDecrease` is 469/469 on the command sheet — so the measured cost on the
command side is **zero**. Nothing else in this document has that ratio.

**Where.** `IntentClassifier/language_packs/en/train.csv`.

**How.** Add SHORT `Default Fallback Intent` rows for the particle senses:
`going down`, `lying down`, `laying down`, `winding down`, `calm down`,
`sit down`, `slow down`, `settle down`, `quiet down`, `keep it down`,
`write it down`, `get down`, `back down`, `speak up`, `hurry up`, `hands up`,
`pulling up`, `what's up`, `pick up`, `set up`.

Length matters. `down` already appears in 27 `Default Fallback Intent` rows, but
every one of them is a long sentence (`ashes to ashes all fall down`,
`i was down 17 grand earlier today`) and none constrains the one- and two-feature
region where the failure lives. That analysis is in
`QADataBasedDecision_SingleTokenCollapse.md` §4.1.

**Verify.** Full `holdout_honest.csv` re-run plus a replay of this corpus;
`Cmd.VolumeDecrease` must stay at 469/469.

### P1 — `timer`, and the vocabulary gate that should have caught it

**Why.** A named product capability that works on 5 of 19 phrasings, and which
fires the wrong command twice (§4.1). The gate matters more than the word.

**Where and how — three parts, in this order.**

1. **Training data** — `train.csv`: add `timer`, `timers`, `seconds`, `second`
   rows for `reminders.add`, and the 25 missing number words. Remove the ASR
   artefacts `1523`, `3334`, `328`, `148`, `74` at source.
2. **A declared trigger lexicon** — each intent declares the surface forms the
   product promises to understand (`reminders.add`: remind, reminder, alarm,
   **timer**, wake me, ping me…). Today nothing in the pack records that "timer"
   is a way to say "reminder", which is why nobody noticed it was missing.
3. **A compiler gate** — `nlu_compiler`: assert that every declared trigger form
   is present in the fitted unigram vocabulary; fail the build otherwise. This
   turns the next `timer` from a QA discovery into a build error.

**Do not** ship a keyword rule for `timer` as anything but a stop-gap. It works
only because `ruleOnly` sets `conf = 1.0`, which trips the §3.3 bypass and
disables the OOV guard for that turn — it exploits the defect in P4 rather than
fixing anything. It is also blunt: `pause the timer` and `cancel the timer` would
route to `reminders.add`. If it ships, it ships with an expiry note pointing at
this section.

### P2 — the help-marker pattern, both directions

**Why.** §3.4 — two unambiguous reminder requests die, plus the `how do you` gap
from `QADataBasedDecision_Help.md` §3.2. One pack field, both defects.

**Where.** `language_packs/en/platform.yaml` → `help_marker_guard.markers`.

**How.**
- Add `how do you`, `how do we`, `how can you`, `how would you` to the
  under-triggering side.
- Narrow `(\w+\s+help\b)` so it does not capture "can you help me *do* X". A
  request for assistance is not a request for instructions.

**Separately, and not in the same change:** §3.4's re-read behaviour is a design
decision recorded in the source (`NLUEngine.swift:558`), not a bug. Whether a
guarded redirect should clear the full 0.70 bar is the open question stated in
`QADataBasedDecision_Help.md` §5 D.10. Keep the pattern fix and that question
apart so the pattern fix can ship immediately.

### P3 — `Cmd.MemoryChange` versus `Help_ChangingMemories` / `Help_MemoryOptions`

**Why.** 51 rows answered with a help card at 0.98+ confidence (§4.3a). The
confidence is the tell: more training data will not move a model that is certain.

**Where.** `language_packs/en/nlu_schema.json` — intent definitions — **before**
any retraining.

**How.** Give the pairs disjoint scopes, merge them, or add a disambiguation turn.
`change programs` genuinely is ambiguous between performing the change and asking
how; a human would ask back. This is a product decision and it blocks the
training-data work, because training two overlapping intents harder sharpens the
boundary without making it correct.

### P4 — decouple the OOV guard's trigger from the arbitration confidence

**Why.** §3.3 — a keyword-rule match silently switches the guard off. Latent
today (2 `ruleOnly` rows in 2,381), but it is the mechanism any rule-based fix
would ride on, and P1's stop-gap would ride on it directly.

**Where.** `VoiceAIKit/Sources/VoiceAIKit/NLU/Engine/NLUEngine.swift` (the guard
condition) and `Pack/Loader/PackEngineFactory.swift` (`PackClassifierAdapter`).

**How.** The guard should test the *model's* confidence in the returned intent,
not the arbitration verdict's synthetic `1.0`. `IntentResult` already carries
`breakdown.stage2`, so the number is available without new plumbing.

**Measure separately** from P5 — this changes which turns the guard inspects.

### P5 — VIK-073, class-aware degeneracy guard

**Why.** §3.2 and §4.1 are the same mechanism. The measured variant is in
`QADataBasedDecision_SingleTokenCollapse.md` §3.5 (via the Help report): 1344
(91.43%) / 6 wrong actions, versus 1346 / 7 for base.

**This report strengthens the case materially** — the collapse now has a measured
rate on QA-labelled data (§3.2) and a second worked example that is a shipped
product feature rather than a probe (`start a timer` → `Cmd.TranscribeStart`).

**Where.** `PackTFIDFVectorizer` (expose the non-zero feature count —
`vectorize(_:)` already computes it as `counts.count`), `PackIntentClassifier`,
`NLUEngine` (the bypass condition), plus an `is_state_changing` flag per intent in
`nlu_schema.json` and the compiler, because no runtime can currently tell a
state-changing intent from a read-only one.

### P6 — cancel cues (VIK-068)

**Where.** `platform.yaml` (`cancel_cues`) + `NLUEngine.handleSlotFilling`, mirroring
`engine.py:242-244, 862+` including the purity guard so "no, tomorrow at 5" reads
as a correction rather than a cancellation.

**Why here and not higher.** 3 rows in this corpus — but the corpus contains no
mid-flow traffic, so it cannot size this. The defect is structural: there is no
exit from a slot flow except exhausting `max_slot_attempts`.

### P7 — QA corpus: separate slot answers from commands

**Why.** §5 — 232 rows across `reminders.*` and `Cmd.MemoryChange` are scored
against a question the harness cannot ask. They depress `reminders.add` from 89.2%
to 51.5% and `Cmd.MemoryChange` by a comparable margin.

**How.** Move them to their own sheet, scored in slot-filling mode (prime the
engine with the pending intent before the phrase) rather than standalone. Keep a
copy in the out-of-scope safety sheet, because §5.2 shows they carry a real signal
there.

**Also add to `PhraseReport.swift`:** `features`, `oov`, and — when `arbitration`
is `ruleOnly` — the rule's own intent. §3.2, §3.3 and §4.1 all required an
external simulator because those three columns are absent.

### Architecture track — delexicalise slot spans before featurisation

Not a numbered priority because it is a larger change than any item above, and it
must not be sequenced against them.

§4.1 shows the model needing `two minutes` for arithmetic reasons rather than
semantic ones: the OOV ratio is `unknown ÷ total`, so adding known words dilutes
it. The pack already declares `sys.date-time` and `sys.number-integer` as dynamic
entities and `memory` / `recurrence` / `remind` as closed enums — but the resolver
runs *after* classification. Running it *before*, and replacing matched spans with
placeholders in both training and inference, would collapse
`for two minutes` / `for 15 minutes` / `for 30 seconds` into one vector, remove the
84 numeric bigrams and 20 digit unigrams from the vocabulary, and stop the ratio
from counting values it was never meant to judge.

**Measured limit, so this is not oversold.** Of the 79 corpus rows that depend on
`oov_bypass`, the breakdown is **48 other unknown words, 29 proper nouns, 2
number/time**. Delexicalisation removes the number/time class and nothing else —
proper nouns need P5. The two are complementary, not alternatives.

This is `VIK-056` (text normalisation) widened from contractions to entity
delexicalisation. It should stay **one** ticket and one transform chain: two
tickets would produce two transform chains, which is exactly how the three runtimes
have diverged before.

### Sequencing

| step | items | why together / apart |
|---|---|---|
| 0 | P3 (taxonomy), P1.2–P1.3 (lexicon + gate) | no model change; both unblock later work |
| 1 | P0, P1.1, P2 | training data and one pack field; one retrain, one holdout run |
| 2 | P4 | alone — it changes which turns the guard inspects |
| 3 | P5 | alone — its own holdout measurement |
| 4 | P6, P7 | independent of the decision path |
| — | architecture track | its own plan, its own measurement, after step 3 |

**Steps 2, 3 and the architecture track must not land together.** VIK-055 is the
precedent: a net accuracy figure concealed a −10 that a three-way split reduced to
−1, and only the per-row listing revealed it.

---

## 7. Caveats

- The §3.1 judgement that 6 of the 39 state-changing rows are QA-labelling errors
  rather than engine errors is judgement, not measurement. The full 27-row table is
  printed above so each row can be disputed.
- §5.1's split uses the presence of `remind` / `reminder` / `timer` / `alarm` as
  the test for "is this a standalone command". It is a heuristic; the 83/116 split
  moves if the test changes.
- Feature counts, OOV ratios and vocabulary membership come from the simulator
  described in the Method note, not from the TSVs, which do not carry those
  columns (see P7).
- `PhraseReport` runs every phrase through a reset engine. Nothing in this
  document describes multi-turn behaviour, and §4.4 in particular cannot be sized
  from this corpus.
- Every proposal in §6 that is marked unmeasured is unmeasured. P5 is the only
  engine change here with a holdout number behind it, and that number is +1 row.
