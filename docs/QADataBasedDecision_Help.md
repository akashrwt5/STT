# QA data-based decision — the `Help_*` phrase report

**Input:** `phrase-report-Help--.tsv`, produced by
`VoiceAIKit/Tests/VoiceAIKitTests/PhraseReport.swift` with
`PhraseScope.selected = .help`, on branch
`…-Porting-Python-logic-VIK-055-keyword-arbitration` against `pack-en-v1.0.54`.

**Shape:** 211 distinct phrases, 400 rows (occurrence-weighted), 24 `Help_*` labels.

Companion documents:
[`QADataBasedDecision_VOlumeIncrease.md`](./QADataBasedDecision_VOlumeIncrease.md) (one
command intent) and
[`QADataBasedDecision_SingleTokenCollapse.md`](./QADataBasedDecision_SingleTokenCollapse.md)
(the engine-level collapse). This one covers the read-only half of the taxonomy.

Everything below is read off the TSV or off the shipped pack and source. Where a
number required judgement — deciding that a QA label is wrong — the full list is
printed so the judgement can be checked rather than taken on trust.

---

## 0. Three accuracy numbers, and why only the third is usable

| measure | value | what it counts |
|---|---:|---|
| distinct-phrase match rate | 105 / 211 = **49.8%** | every phrase once |
| row-weighted match rate | 258 / 400 = **64.5%** | what the TSV reports |
| **after crediting correct fallbacks** | 326 / 400 = **81.5%** | the honest figure |

The gap between the second and third is 68 rows in which **the engine is right and
the QA label is wrong.** The corpus was mined per-intent, so a phrase inherits the
label of the Dialogflow intent it was found under, not the label it deserves:

- `what is the temperature in International Falls` ×10 — labelled `Help_FallAlert`
- `where are the Black Hills located` ×4 — labelled `Help_FindMyHearingAids`
- `tell me in detail of the solow growth model` ×3 — labelled `Help_DeviceSettings`
- `is President Biden in good health` ×2 — labelled `Help_Health`
- `how do I calculate standard deviation`, `how hot do I cook my chicken to`,
  `what phase is the moon currently in` — labelled `Help_Volume` / `Help_ChangingMemories`

All 56 such phrases are listed in §7. The engine sends every one of them to
`Default Fallback Intent`, which is correct.

**And there is a fourth number that matters more than any of them.**

| slice | rows | match |
|---|---:|---:|
| `Help_Volume` | 171 (**43% of the corpus**) | 88% |
| everything else | 229 | **47.2%** |

One intent is nearly half the corpus and it is the one that works. Quoting a single
headline figure for `Help_*` hides that. **Read the per-label table in §1, not the
headline.**

---

## 1. Per-label results

Occurrence-weighted.

| label | hit | rows | % |
|---|---:|---:|---:|
| Help_EdgeMode | 8 | 8 | 100% |
| Help_Tinnitus | 4 | 4 | 100% |
| Help_CleanCare | 25 | 27 | 93% |
| Help_Volume | 150 | 171 | 88% |
| Help_MemoryOptions | 8 | 10 | 80% |
| Help_Battery | 6 | 8 | 75% |
| Help_ChangingMemories | 16 | 24 | 67% |
| Help_WhatsNew | 4 | 6 | 67% |
| Help_InsertDevice | 2 | 3 | 67% |
| Help_SelfCheck | 8 | 13 | 62% |
| Help_Reminder | 2 | 4 | 50% |
| Help_DeviceSettings | 5 | 13 | 38% |
| Help_FallAlert | 8 | 21 | 38% |
| Help_WiCROS | 1 | 3 | 33% |
| Help_FindMyHearingAids | 3 | 9 | 33% |
| Help_AppSettings | 1 | 4 | 25% |
| Help_RemoteProgramming | 4 | 28 | 14% |
| Help_Pairing | 1 | 9 | 11% |
| Help_Health | 1 | 9 | 11% |
| Help_VoiceAssistant | 1 | 15 | 7% |
| Help_Home | 0 | 5 | 0% |
| Help_Accessories | 0 | 2 | 0% |
| Help_Customize | 0 | 2 | 0% |
| Help_IntelliVoice | 0 | 2 | 0% |

The bottom of this table is mostly §0's labelling problem — `Help_FallAlert` at 38%
is 13 rows of weather and driving distances. But `Help_RemoteProgramming` (28 rows,
14%) and `Help_VoiceAssistant` (15 rows, 7%) are real, and both are fixable in
training data. See §4.

---

## 2. What is working

### 2.1 VIK-055 arbitration, visible in QA data

The exact defect that started this engagement appears in the report and is now
handled:

```
who is the PM of create reminder
  model = Default Fallback Intent  0.4676
  arbitration = contested
  final = Default Fallback Intent  conf 0.6000  (bar 0.70)
```

A keyword rule claimed `reminders.add`; the model answered out of scope; the
three-way arbitration capped the confidence at `contestedConfidence` 0.60, which
cannot clear the 0.70 fire bar. Before VIK-055 this opened the reminder flow.

`corroborated` appears 3 times (4 rows), all correct. `contested` once.
`ruleOnly` 11 times (18 rows) — see §3.4, where it does not come out well.

### 2.2 The ND-14 help guard, doing its job

Seven distinct phrases (14 rows) show the guard working end to end: a keyword rule
fires a `Cmd.Volume*` intent, `helpRedirect` rewrites it to `Help_Volume`, and the
re-read confidence is high because the model had independently said `Help_Volume`.

| phrase | rows | model | final |
|---|---:|---|---|
| how do I increase volume | 8 | Help_Volume 0.9499 | Help_Volume ✅ |
| how do I change the volume louder | 1 | Help_Volume 0.9964 | Help_Volume ✅ |
| how do I decrease volume | 1 | Help_Volume 0.9993 | Help_Volume ✅ |
| how do I increase my volume | 1 | Help_Volume 0.9861 | Help_Volume ✅ |
| how do I increase the volume | 1 | Help_Volume 0.9973 | Help_Volume ✅ |
| how do I turn down my volume | 1 | Help_Volume 0.9904 | Help_Volume ✅ |
| how do I turn up my volume | 1 | Help_Volume 0.9810 | Help_Volume ✅ |

Asking how to change the volume shows the help card. That is ND-14's whole purpose
and on this corpus it holds.

### 2.3 Fallback discipline

84 distinct phrases go to fallback, and the large majority of them should. The
engine is not over-firing on `Help_*` traffic — the failure mode here is the
opposite one (§4).

---

## 3. What is broken — engine-side

### 3.1 Six rows change device state

A phrase carrying a `Help_*` label reaches a state-changing command.

| phrase | QA label | fires | conf | cause |
|---|---|---|---:|---|
| how do you turn the volume up on the hearing aid | Help_Volume | Cmd.VolumeIncrease | 1.0000 | **help-guard marker gap** (§3.2) |
| silence change the volume | Help_Volume | Cmd.VolumeMute | 1.0000 | **keyword rule overrules the model** (§3.4) |
| turn on hearing aid maintenance on reminders screen | Help_Reminder | Cmd.VolumeUnmute | 0.9798 | model error |
| play ringtone | Help_DeviceSettings | Cmd.ListenMessage | 0.9961 | model error |
| start cleaning | Help_CleanCare | Cmd.TranscribeStart | 0.7559 | model error |
| text meaning | Help_FallAlert | Cmd.SendMessage → CONFIRM | 0.8783 | model error / bad label |

**Read this table carefully — the six are not one defect.**

Only the first is a help question that triggers the thing it asks about. The last
four are **not questions at all**: `play ringtone`, `start cleaning`,
`turn on hearing aid maintenance on reminders screen` and `text meaning` are
imperatives or fragments that happen to carry a `Help_*` label from the mining
pass. The help-marker guard is a question detector; it was never in their path and
tightening it would not touch them. They are ordinary model errors, and two of them
(`text meaning`, `play ringtone`) have questionable labels to begin with.

A further six rows reach a **read-only** command — `status` → `Cmd.BatteryLevel`,
`how can I walk alone` → `Cmd.ActivityWalk`, `show me aerobic activity` and
`what is my aerobic activity` → `Cmd.ActivityAerobics`, `exercise activity` →
`Cmd.ActivityExercise`, `how to recharge a h` → `Cmd.BatteryLevel`. Wrong card, no
state change, much lower cost.

### 3.2 `how do you` is not in the help-marker pattern

The shipped pattern (`runtime/guards.json → help_marker.markers`):

```
(how\s+(to|do\s+i|does|can\s+i|is|would\s+i)\b)|(\bguide\b)|(\bexplain\b)|(\btutorial\b)
|(what\s+(is|are|does)\b)|(where\s+(can|do)\s+i\s+(see|find|view))|(is\s+there\s+a\s+way)
|(help\s+(with|me\s+understand|for|understanding))|(how\s+to\s+use)|(\w+\s+help\b)
|(does\s+\w+\s+(keep|save|store|record|work))|(can\s+the\s+app)
```

`how do i` is there. `how do you` is not. Nor is `how do we`, `how can you`,
`how would you`.

This defect was first recorded in
[`QADataBasedDecision_VOlumeIncrease.md`](./QADataBasedDecision_VOlumeIncrease.md) §3.
The `Help_*` report confirms it on a second family and adds the **precise trigger
condition**, which the earlier report could not establish:

| phrase | rule fires? | outcome |
|---|---|---|
| how do you adjust the volume on hearing aid | no | `Help_Volume` 0.9907 ✅ |
| how do you change the hearing aid volume | no | `Help_Volume` 0.9800 ✅ |
| how do you turn the volume up on the hearing aid | **yes** | **`Cmd.VolumeIncrease` 1.0000** ❌ |

So the marker gap is only *visible* when a keyword rule also fires. With no rule,
the model's own answer (`Help_Volume`) survives and the missing marker costs
nothing. With a rule, `ruleOnly` arbitration hands the turn to the rule and the
guard — the one thing that would put it back — does not match.

Worth stating plainly: **on that row the model was right at 0.9559 and was
overruled.**

### 3.3 The confidence re-read after a guarded redirect — measured, and DECIDED

`NLUEngine.swift:564-579` re-reads the confidence after redirecting, so the number
reported describes the intent actually being returned. The consequence, on this
corpus:

| phrase | rows | redirected to | re-read conf | outcome |
|---|---:|---|---:|---|
| how do I turn off my hearing aids | 3 | Help_Volume | 0.1577 | fallback |
| hi how do I shut off my hearing aids | 1 | Help_Volume | 0.0210 | fallback |
| how to turn the volume up | 1 | Help_Volume | 0.4562 | fallback |
| how to step too low | 1 | Help_Volume | 0.0010 | fallback |
| you can talk to at home soon how do I increase my volume | 1 | Help_Volume | 0.6587 | fallback |

The source comment at `NLUEngine.swift:558` already records the behaviour: *"On
this pack's honest holdout, keeping it deflected 11 of 12 guarded turns to the
fallback."*

#### Why it happens — the mechanism, which the code comment does not state

The re-read confidence is the model's probability for the **sibling**, taken from
the same distribution as its probability for the command. Softmax normalises, so
if the model puts *p* on the command, the sibling can have at most *1 − p*:

```
how can i turn up the volume?   model Cmd.VolumeIncrease 0.9995  ->  p(Help_Volume) 0.0005  -> fallback
how can i mute my hearing aids  model Cmd.VolumeMute     0.9742  ->  p(Help_Volume) 0.0059  -> fallback
how do i turn up my volume      model Help_Volume        0.9810  ->  p(Help_Volume) 0.9810  -> fires
how do i increase volume        model Help_Volume        0.9499  ->  p(Help_Volume) 0.9499  -> fires
```

**The two are anti-correlated by construction.** The more certain the model is
that it heard a command, the more certainly the guarded redirect falls back. The
redirect survives only when the model had *independently* chosen the help intent —
that is, only when the guard was not needed. This is arithmetic, not a tuning
accident, and it is why the figure is 11 of 12.

#### The design question, and the answer

> Once `helpRedirect` has fired, the turn has been classified as a help ask by a
> deterministic rule that does not depend on the model's confidence. Why must the
> redirected intent then clear the same bar as an unguarded prediction?

**Measured.** Bypassing the fire test for a guarded redirect (`opt3a`; the OOV
guard still applies) on the full iOS ladder:

| corpus | match | false-fire | wrong-act |
|---|---|---|---|
| QA 5,411 | 4,729 → **4,734** | 39 → 39 | 92 → **91** |
| holdout 1,470 | 1,346 → **1,347** | 3 → 3 | 7 → 7 |

And it is structurally safe: all six distinct redirect targets are `Help_*`
intents (`Help_Accessories`, `Help_MemoryOptions`, `Help_Reminder`,
`Help_Transcribe`, `Help_Translate`, `Help_Volume`), so skipping the fire test
cannot produce a device action — only a card.

**It was nevertheless REJECTED, and the current behaviour is correct.** Row by row,
`opt3a` turns 4 fallbacks into the *right* help card and 8 into the *wrong* one:

```
right topic   how to turn the volume up / how do I turn off my hearing aids
              you can talk to at home soon how do I increase my volume
              how to increase volume (holdout)

wrong topic   hi how do I shut off my hearing aids   truth Help_Pairing      -> Help_Volume
              how do i turn up the tv volume?        truth Help_Accessories  -> Help_Volume
              how to step too low                    truth Help_Health       -> Help_Volume
              how can I add reminder                 truth reminders.add     -> Help_Reminder
              (+4 more)
```

**Product decision: "I did not understand" is preferable to a possibly-wrong help
card.** Under that rule `opt3a` is 4 good against 8 bad — net negative.

An attempt to keep the good and drop the bad by gating on the model's confidence
in the **command** was measured and fails: the good cases span 0.5427–0.9995 and
the bad cases span 0.4035–1.0000, with two bad cases at exactly 1.0000 because
`ruleOnly` assigns a synthetic confidence. No threshold separates them.

**So the re-read is not a defect — it implements the product's stated preference.**
Earlier revisions of this document described it as a defect; that framing assumed
the product would prefer a card, and the product does not.

**What this leaves.** `how can i turn up the volume?` still answers "I did not
understand", and that is genuinely poor. The fix is not in the engine: the model
must learn the phrasing, exactly as it already knows `how do i increase volume`
(which it labels `Help_Volume` at 0.9499 and which therefore never needs the
guard). This is training-data work — see the plan's P0/P3 retrain — not a
threshold change.

### 3.4 On `Help_*` traffic the keyword layer is net-negative

Keyword rules touch 23 of 400 rows (5.75%). The 18 `ruleOnly` rows break down:

| outcome | distinct | rows | note |
|---|---:|---:|---|
| correct `Help_Volume` | 7 | 14 | **the model had already predicted `Help_Volume`** |
| wrong action | 2 | 2 | `how do you turn the volume up…`, `silence change the volume` |
| fallback | 2 | 2 | `how to step too low`, `you can talk to at home soon…` |

Every one of the 14 "correct" rows shows `model = Help_Volume` in the report, so
without the rule those turns would have fired `Help_Volume` at the same confidence.
**The rule contributed no correct answer that the model did not already have.**

Replaying the corpus with the keyword layer removed changes exactly one row:
`how do you turn the volume up on the hearing aid` becomes a match, because the
model's `Help_Volume` 0.9559 would have stood.

> On this corpus the keyword layer contributes **zero** correct answers and causes
> **one** wrong action.

**Scope limit, and it matters.** This is `Help_*` traffic only. Keyword rules exist
for `Cmd.*` utterances, where the earlier audit measured them hitting ~9% of turns.
Nothing here argues for removing them. What it does argue is that
**`ruleOnly` should not apply when the model's own answer is the rule's paired
`Help_*` sibling** — in that case the model and the guard agree with each other and
only the rule disagrees. That is a narrower change than touching arbitration
generally, and it is unmeasured.

### 3.5 Single-token collapse, again — but here it is cheap, and it inflates the score

The mechanism documented in
[`QADataBasedDecision_SingleTokenCollapse.md`](./QADataBasedDecision_SingleTokenCollapse.md)
is present throughout this report. Measured on the shipped iOS pack, these rows are
**scored as matches** while the OOV guard was stood down by `oov_bypass`:

| phrase | features | oov | conf | fires |
|---|---:|---:|---:|---|
| abortion receiver is | 2 | 0.33 | 0.9995 | Help_WiCROS ✅ |
| the mobile app | 2 | 0.33 | 0.9998 | Help_AppSettings ✅ |
| what is Gold city in reminder | 5 | 0.33 | 0.9921 | Help_Reminder ✅ |
| beep in Minneapolis | 2 | 0.33 | 0.9854 | Help_DeviceSettings ✅ |
| this and get a ding ding in my ear | 8 | 0.25 | 0.9972 | Help_InsertDevice ✅ |
| how do I insert chicks | 5 | 0.25 | 0.9854 | Help_InsertDevice ✅ |
| check check check testing testing | 1 | 0.40 | 0.9783 | Help_SelfCheck ✅ |
| how do I clean miniatures | 5 | 0.25 | 0.9985 | Help_CleanCare ✅ |
| how do I clean myself | 5 | 0.25 | 0.9985 | Help_CleanCare ✅ |
| how can I charge my non-rechargeable hea | 7 | 0.29 | 0.9970 | Help_Battery ✅ |

And a second group that is not even OOV-blocked, because the *question form* carries
the whole decision:

```
how do I clean my chair   -> Help_CleanCare 1.0000   (oov 0.20)
how do I clean my chain   -> Help_CleanCare 1.0000
how do I clean my itchy   -> Help_CleanCare 1.0000
how do I clean my         -> Help_CleanCare 1.0000   (truncated phrase)
how do I charge my YouTube-> Help_Battery   0.9956   (oov 0.00)
```

`how do i clean my` is seven features on its own. Whatever follows it is noise.

**The important asymmetry — and it is a finding, not a restatement.**

On `Cmd.*` this mechanism turns a hearing aid down when someone says *"calm down"*.
On `Help_*` it shows the wrong help card, and the user presses back. Same mechanism,
and the costs are not within an order of magnitude of each other.

That is a direct argument that the degeneracy guard proposed in **VIK-073** should be
**intent-class-aware rather than global**: tighten the bypass only where the
resulting intent is state-changing, and leave it alone where the result is a
read-only card. The engine already has the predicate — `is_state_changing` from
`nlu_training/wrong_action_harness.py` — and iOS knows the intent before the guard
runs.

**Measured**, on `holdout_honest.csv` (n=1470) through the iOS-faithful ladder:

| variant | accuracy | wrong actions |
|---|---:|---:|
| base (shipped) | 1346 (91.56%) | 7 |
| `features >= 2`, applied to everything | 1343 (91.36%) | 6 |
| **`features >= 2`, state-changing intents only** | **1344 (91.43%)** | **6** |

It keeps the full safety benefit — `mute swan`, `mute Michael Jackson`, `calm down`,
`sit down`, `stream Netflix`, `transcribe Beethoven` all go to fallback exactly as
under the flat variant — at one row less cost.

**Be honest about how small that is.** Class-awareness recovers exactly **one**
holdout row (`i need instructions`, gold `Help_Home`). It does **not** recover the
other three the flat variant loses: `its lowd` → `Cmd.VolumeDecrease`,
`retrieve phone` → `Cmd.FindMyPhone` and `audio redirection` →
`Cmd.StreamingStart` all predict state-changing intents, so the tightening still
applies to them and they still fall back. On this `Help_*` corpus it likewise
preserves one matched row (`check check check testing testing`, 1 feature, oov 0.40).

So the argument for class-awareness is not the row count. It is that it **confines
the cost to the class where the safety argument actually applies**, instead of
charging read-only traffic for a command-side problem — and read-only traffic is
where most of the collapse happens (§3.5's first table is ten such rows). The
accuracy delta is +1; the design delta is the point.

---

## 4. What is broken — content-side

Nothing in this section is an engine defect. These are the larger numbers.

### 4.1 The cheapest fix in the report: 12 rows, 0.046 below the bar

```
what is smart assistant     x11   model = Help_VoiceAssistant  0.6539   -> fallback
what is a smart assistant   x1    model = Help_VoiceAssistant  0.6539   -> fallback
```

The model names the correct intent and misses the 0.70 fire bar by **0.046**. Twelve
rows — 3% of the entire corpus — and `Help_VoiceAssistant` sits at 7% almost
entirely because of it. A handful of training rows fixes this.

**Do not fix it by lowering the threshold.** 0.70 is measured and shared with every
other intent; moving it to rescue one phrase family would be the `oov_bypass → 0.90`
mistake in a different place.

### 4.2 The audiologist cluster — 7 rows, same shape

| phrase | rows | model | conf |
|---|---:|---|---:|
| how do I add the audiologist | 3 | Help_RemoteProgramming | 0.5140 |
| how do I add my audiologist | 2 | Help_RemoteProgramming | 0.6666 |
| how do I connect an audiologist | 1 | Help_RemoteProgramming | 0.5284 |
| How to use Audiologist | 1 | Help_Reminder | 0.6020 |

Right intent, under the bar. Plus `how do I add an audiologist` ×6, which fires the
**wrong** help intent (`Help_DeviceSettings` 0.8277) — see §4.3.

Together the audiologist family is 13 of `Help_RemoteProgramming`'s 28 rows and is
most of why that label reads 14%.

### 4.3 Two help intents answering the same question — 18 rows

| phrase | rows | QA wants | engine gives | conf |
|---|---:|---|---|---:|
| how do I add an audiologist | 6 | Help_RemoteProgramming | Help_DeviceSettings | 0.8277 |
| how do I change my hearing aids | 3 | Help_ChangingMemories | Help_DeviceSettings | 0.8382 |
| how do I use learn tab | 2 | Help_RemoteProgramming | Help_Home | 0.9438 |
| how do I change my name | 1 | Help_Accessories | Help_DeviceSettings | 0.7667 |
| how do I use my Hearing Aid | 1 | Help_Home | Help_Battery | 0.9419 |
| sync my hearing aids | 1 | Help_RemoteProgramming | Help_HearingCareAnywhereConnect | 0.9181 |
| how do I control my ringtone | 1 | Help_Volume | Help_WiCROS | 0.9337 |
| what is my health volume | 1 | Help_Volume | Help_Health | 0.9994 |
| eat my hearing aids | 1 | Help_FindMyHearingAids | Help_CleanCare | 0.7048 |
| are my hearing aids synced with my hearing aids together | 1 | Help_Pairing | Help_CleanCare | 0.8127 |

The high confidences are the tell. The model is not uncertain — it is confidently
choosing a different intent that covers overlapping ground. `how do I change my
hearing aids` genuinely is ambiguous between changing *programs* and changing
*device settings*; a human would ask back.

**This is taxonomy work, not model work.** Either the intents get disjoint scopes,
or the overlapping pairs get a disambiguation turn. No amount of training data fixes
two intents that mean the same thing.

### 4.4 Ambiguous or truncated phrases — leave them

`connect`, `status`, `changed`, `start screen`, `how do I add`, `Telecare`,
`hedge mode`, `switching back and forth`, `create a new binder`. Some are ASR
truncations, some are genuinely ambiguous out of context. `Telecare` scores exactly
**0.0000** — a zero-feature utterance (see the dead-guard note in
`QADataBasedDecision_SingleTokenCollapse.md` §7).

Fallback is the right answer for these. They are counted as misses and should not be.

---

## 5. Summary — what to fix, and where

Ordered by evidence, not by effort.

### A. Pack content — `language_packs/en/platform.yaml`

1. **Add `how do you` to `help_marker.markers`**, with `how do we`, `how can you`
   and `how would you`. One phrase family in this report acts on the device because
   of its absence, and §3.2 gives the exact trigger condition (a keyword rule must
   also fire), which makes it testable.
   *Also raised in `QADataBasedDecision_VOlumeIncrease.md` §9 A — this is the second
   corpus to hit it. Do it once, for both.*
2. **Do not touch `confidence: 0.70` or `oov_bypass: 0.97`** to rescue §4.1 or §3.5.
   Both are measured and shared across every intent.
3. Nothing in the signed `pack-en-v1.0.54` is hand-edited. Everything goes through
   the compiler.

### B. Training data — `language_packs/en/train.csv`

4. **`what is smart assistant` family** — 12 rows at 0.6539. Highest return per row
   in the report (§4.1).
5. **The audiologist family** — 7 rows at 0.51–0.67, plus 6 more going to the wrong
   help intent (§4.2).
6. Re-measure `Help_VoiceAssistant` and `Help_RemoteProgramming` after the retrain;
   both labels' headline numbers are dominated by these two families.

### C. Taxonomy — intent definitions, before any retraining

7. **Resolve the overlapping pairs in §4.3** — `Help_RemoteProgramming` vs
   `Help_DeviceSettings`, `Help_ChangingMemories` vs `Help_DeviceSettings`,
   `Help_Home` vs everything. 18 rows, all with high confidence, which means more
   training data will not help until the scopes are disjoint.
8. This blocks B. Training two overlapping intents harder makes the boundary
   sharper without making it *correct*.

### D. Engine — `NLUEngine` / arbitration

9. **VIK-073 should be intent-class-aware** (§3.5). Tighten the OOV bypass where the
   resulting intent is state-changing; leave it where the result is read-only.
   **Measured:** 1344 (91.43%) / 6 wrong actions, versus 1343 / 6 for the flat
   variant and 1346 / 7 for base. It keeps the whole safety benefit and costs one
   row less. The row count is not the argument — confining the cost to the class
   that carries the risk is. This is the main thing this report contributes to that
   ticket.
10. **Ask whether a guarded redirect should clear the full fire bar** (§3.3). It
    replaces a command with a read-only card, so it is strictly safer than what it
    replaced. **Unmeasured**, and the holdout will undercount the benefit.
11. **Consider suppressing `ruleOnly` when the model's prediction is the rule's
    paired `Help_*` sibling** (§3.4). Narrow, targeted, and it removes one of the two
    rule-caused wrong actions without touching arbitration generally. **Unmeasured.**
12. Items 9–11 are three separate measurements. **Do not land them together** — the
    same attribution problem that made the VIK-055 two-way design look free.

### E. QA corpus

13. **Re-label the 56 out-of-scope phrases in §7**, or add an explicit
    `Default Fallback Intent` sheet. Today a correct fallback is scored as a miss,
    which costs 68 rows — 17% of the corpus — and makes every `Help_*` number look
    worse than it is.
14. **The report needs `features` and `oov` columns.** §3.5 could not be written
    from the TSV alone; it needed an external simulator. Adding them to the `decide`
    log and to `PhraseReport.swift` makes the next audit self-contained. *Same ask as
    `QADataBasedDecision_SingleTokenCollapse.md` §9 A.2.*
15. **The report does not carry the keyword rule's intent.** When `arbitration` is
    `ruleOnly`, the rule's own label is invisible, so §3.4 had to be inferred from
    the model and final columns. One more column closes that gap.

### F. Open, not investigated

16. Whether the overlap in §4.3 also affects `Cmd.*` ↔ `Help_*` routing in the
    reverse direction — a command being answered with a help card. This report only
    sees `Help_*` labels, so it cannot say.
17. Whether the guard fires on any path this report cannot see. Detection in §3.3
    relied on the final confidence differing from the model confidence; a redirect
    whose re-read happens to equal it is invisible here.

---

## 6. Proposed measurement before anything in §5 D ships

**Item 9 is measured** (§3.5), on the same holdout and the same ladder as the flat
`features >= 2` variant in `QADataBasedDecision_SingleTokenCollapse.md` §6, so the
two are directly comparable. It still needs the usual review: one row of movement is
inside the noise a different holdout split would produce, and the case for it rests
on the design argument, not the number.

**Items 10 and 11 are not measured.** Each needs its own run on `holdout_honest.csv`
(n=1470) through the iOS-faithful ladder, reporting accuracy **and**
`wrong_action_count`, and each needs the rows it moves listed — not just the net.
The VIK-055 episode is the precedent: a net figure hid a −10 that a three-way split
reduced to −1, and the rows were what showed it.

Item 10 (lowering the bar for a guarded redirect) has a second requirement: the
holdout cannot score its benefit, because a redirect deflected to fallback and a
redirect delivered as a help card are the same single row to it. That is the §13.9
limitation again, and it means the measurement can only bound the cost.

---

## 7. Appendix — the 56 phrases whose QA label is wrong

Listed so the §0 adjustment can be checked. In every one of these the engine returns
`Default Fallback Intent`, which is the correct answer.

```
how do I get a room for my girlfriend          how to convert ft into inches
what phase is the moon currently in            what is E equals MC square
what is E equals MC squared                    tell me in detail of the solow growth model  (x2)
tell me in detail about the solos close model  what is the temperature in International Falls (x7)
temperature in International Falls (x2)        what's the temperature in International Falls
how many miles from International Falls to Eden Prairie
how many miles from International Falls to Minneapolis
where are the Black Hills located (x4)         is President Biden in good health (x2)
I see afterwards.                              voice and I can appreciate so that
who was the voice of India after Independence  what are some things to do in Minneapolis
how do I calculate standard deviation          how do I know my horoscope
how do I PM of India meet                      how hot do I cook my chicken to
that's why I asked                             I seen that I'm struggling to follow conversations and group settings
another problem                                checking cashing
not working after that                         oh now it started working
working in Africa                              clean here and here and here
be honest video                                if you want a personal assistant okay
from one of the following devices to streamer about my father by hearing aids
popular versions and then they have a cable receiver on the end of it
broadcast to receiver receiver mess yeah that's not how we do things
Telecare TV will not rotate                    how do I use Snapchat
A for effort beep for delivery                 change the correctional
change the Landscaping                         Jacob programs Auditorium
Transit programs Auditorium                    sweetnight hearing aids
changed Apartments                             show me balanced assessment
screaming check screening check                adjust free download
how do I adjust my darling                     how do I change your clears
how to control my bio                          open Waze app
go to Bruno                                    create a song
how do I use you                               what are these programs to like a flat
who is the PM of create reminder
```

The last one is the VIK-055 defect phrase. It is labelled `Help_Reminder` in the
corpus and scored as a miss, but fallback is exactly the behaviour VIK-055 shipped
to produce.

## 8. Caveats

- The classification in §7 is judgement, not code. The list is printed in full so it
  can be disputed row by row. §0's 81.5% moves if any row is disputed.
- The feature counts and OOV ratios in §3.5 are not in the TSV; they come from the
  iOS-faithful simulator described in
  `QADataBasedDecision_SingleTokenCollapse.md` §10, which was validated against real
  device output for the `Cmd.VolumeMute` report.
- §3.4's "zero correct answers contributed" is a replay of this corpus only. It is
  not a claim about `Cmd.*` traffic, where the keyword layer was measured hitting
  ~9% of turns.
- Of the three proposals in §5 D, only item 9 is measured. Items 10 and 11 are
  design arguments with no numbers behind them yet and must not be implemented on
  the strength of this document alone.
