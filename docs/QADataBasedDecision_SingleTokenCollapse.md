# QA data-based decision — single-token collapse and the OOV bypass

**Scope:** engine-level, not intent-level. Everything below applies to every intent in
the pack. It was found while auditing `Cmd.VolumeIncrease` and `Cmd.VolumeMute`
(see `QADataBasedDecision_VOlumeIncrease.md`), but it does not belong in either
report: the mechanism is in `PackTFIDFVectorizer` + `NLUEngine`, and the two volume
intents are simply where it is easiest to see.

**Verdict in one sentence:** the featuriser discards every token outside its
vocabulary, so a phrase carrying one high-signal command word produces the *same*
vector as that word alone and the head returns a near-1.0 confidence for it — and
`oov_bypass = 0.97`, the condition that stands the OOV guard down, is satisfied by
exactly those cases, so the guard that exists to catch them is the thing that lets
them through.

All numbers below were produced with an iOS-faithful simulator (full head weights,
`temperature_coreml_full`, the iOS unigram vocabulary) that was validated against
real device output — it reproduces the on-device result for every miss in the
`Cmd.VolumeMute` phrase report. Nothing here is inferred from documentation.

---

## 1. The mechanism

The vectoriser tokenises with sklearn's `(?u)\b\w\w+\b`, looks each feature up in
`vocabulary`, and **drops anything it does not find**. There is no `<unk>` column.
So an unknown word is not weighed and rejected — it is not seen at all.

`PackTFIDFVectorizer.swift:63-71` already says this, in the `oovRatio` docstring
written for VIK-054:

```
"turn off"          -> 3 non-zero features
"turn off toshiba"  -> 3 non-zero features, cosine 1.000000
```

What that audit recorded as a property of one pair of strings is general. Measured
on the shipped iOS pack:

| utterance | features the model actually sees | model | confidence |
|---|---|---|---|
| `down` | `['down']` | `Cmd.VolumeDecrease` | 0.9998 |
| `sit down` | `['down']` | `Cmd.VolumeDecrease` | 0.9998 |
| `calm down` | `['down']` | `Cmd.VolumeDecrease` | 0.9998 |
| `slow down` | `['down']` | `Cmd.VolumeDecrease` | 0.9998 |
| `settle down` | `['down']` | `Cmd.VolumeDecrease` | 0.9998 |
| `up` | `['up']` | `Cmd.VolumeIncrease` | 0.9996 |
| `hurry up` | `['up']` | `Cmd.VolumeIncrease` | 0.9996 |
| `hands up` | `['up']` | `Cmd.VolumeIncrease` | 0.9996 |
| `mute` | `['mute']` | `Cmd.VolumeMute` | 0.9946 |
| `mute swan` | `['mute']` | `Cmd.VolumeMute` | 0.9946 |
| `mute Michael Jackson` | `['mute']` | `Cmd.VolumeMute` | 0.9946 |

These are not similar vectors. They are **the same vector**. `sit`, `calm`, `slow`,
`settle`, `hurry`, `hands`, `swan`, `michael`, `jackson` are not in the unigram
vocabulary, and neither is any bigram they would form, so nothing distinguishes the
phrase from the bare token. No threshold can separate them and no training row can
teach the difference — the model is never asked the question.

And a one-feature vector is the *easiest* input a linear head can score: after
L2 normalisation it is a unit vector pointing straight down one coefficient column,
so the logit gap is maximal and the softmax saturates. **Degeneracy produces high
confidence, not low confidence.** That inversion is the whole problem.

---

## 2. Why the OOV guard does not catch it

The guard exists precisely for this. `NLUEngine.swift:663`:

```swift
if let reject = oovReject, let bypass = oovBypass, !outOfScope, conf < bypass {
    let ratio = await classifier.oovRatio(text)
    ...
}
```

`oov_reject = 0.25`, `oov_bypass = 0.97`.

`mute swan` has an OOV ratio of 0.50 — comfortably above `oov_reject`. The guard
would refuse it. It never runs, because `conf` is 0.9946, which is `>= 0.97`, so the
guard stands down before it looks at the ratio.

The bypass is not a bug in itself. Its stated reason (`engine.py:1265-1280`, mirrored
in the Swift comment at `NLUEngine.swift:611`) is sound and was measured: a slot value
— a name, a brand, a reminder topic — can never be in a finite vocabulary, so a bare
ratio test refuses real commands:

```
'send a message to john'   oov 0.25, conf 1.000   <- a real command
'stream from netflix'      oov 0.33, conf 0.996   <- a real command
'help me find a paper'     oov 0.25, conf 0.771   <- out of scope
```

The reasoning is: *high confidence means the remainder reads unambiguously, so the
unknown token is the value the command operates on.* That inference holds when the
remainder is substantial. It fails when there **is** no remainder — when the
confidence is high *because* only one token survived. The bypass cannot tell
"`send a message to` + an unknown name" from "an unknown phrase that happened to
contain `mute`", because by the time it looks, both are just a confidence number.

So the guard's exemption condition and the failure mode it is meant to catch are
satisfied by the same inputs.

---

## 3. Evidence

### 3.1 Everyday English, none of it addressed to the device

18 ordinary phrases a person might say in a room with a hearing aid in it, run
through the full iOS ladder:

| phrase | model | conf | features | oov | final | acts? |
|---|---|---:|---:|---:|---|---|
| sit down | Cmd.VolumeDecrease | 0.9998 | 1 | 0.50 | Cmd.VolumeDecrease | **yes** |
| calm down | Cmd.VolumeDecrease | 0.9998 | 1 | 0.50 | Cmd.VolumeDecrease | **yes** |
| slow down | Cmd.VolumeDecrease | 0.9998 | 1 | 0.50 | Cmd.VolumeDecrease | **yes** |
| settle down | Cmd.VolumeDecrease | 0.9998 | 1 | 0.50 | Cmd.VolumeDecrease | **yes** |
| hold on | Default Fallback Intent | 0.9763 | 3 | 0.00 | Default Fallback Intent | no |
| speak up | Cmd.VolumeIncrease | 0.7972 | 2 | 0.00 | Cmd.VolumeIncrease | **yes** |
| hurry up | Cmd.VolumeIncrease | 0.9996 | 1 | 0.50 | Cmd.VolumeIncrease | **yes** |
| back down | Cmd.VolumeDecrease | 0.9991 | 2 | 0.00 | Cmd.VolumeDecrease | **yes** |
| lie down | Cmd.VolumeDecrease | 0.7214 | 2 | 0.00 | Cmd.VolumeDecrease | **yes** |
| write it down | Cmd.VolumeDecrease | 0.9535 | 4 | 0.00 | Cmd.VolumeDecrease | **yes** |
| get down | Cmd.VolumeDecrease | 0.9859 | 2 | 0.00 | Cmd.VolumeDecrease | **yes** |
| turn around | Help_Home | 0.6356 | 2 | 0.00 | Default Fallback Intent | no |
| keep it down | Cmd.VolumeDecrease | 0.9914 | 4 | 0.00 | Cmd.VolumeDecrease | **yes** |
| quiet down | Cmd.VolumeDecrease | 0.9997 | 2 | 0.00 | Cmd.VolumeDecrease | **yes** |
| shut up | Default Fallback Intent | 0.8810 | 3 | 0.00 | Default Fallback Intent | no |
| listen up | Cmd.VolumeIncrease | 0.5338 | 2 | 0.00 | Default Fallback Intent | no |
| hands up | Cmd.VolumeIncrease | 0.9996 | 1 | 0.50 | Cmd.VolumeIncrease | **yes** |
| stand up | Cmd.ActivityStand | 0.8740 | 2 | 0.00 | Cmd.ActivityStand | yes (read-only) |

**14 of 18 reach an intent. 13 of those change device state.** Only `hold on`,
`turn around`, `shut up` and `listen up` land on fallback.

`quiet down` deserves its own line: it is the single most natural way in English to
ask a *person* to be quieter, and it turns the hearing aid down at 0.9997.

### 3.2 Corpus-wide

Across the QA corpus (`Fixtures/help_intent_phrases.json`, 5,411 rows / 1,844
distinct phrases), counting only rows that **fire a non-fallback intent while the
OOV guard was stood down by the bypass**:

```
total exempted-and-fired rows: 79  (68 distinct)
  22 rows /  21 distinct with 1 feature
  10 rows /   9 distinct with 2 features
  10 rows /   8 distinct with 3 features
   7 rows /   7 distinct with 4 features
  26 rows /  19 distinct with 5 features
   5 rows /   5 distinct with 7-9 features
```

Reachable this way: **27 distinct intents**, led by `Cmd.MemoryChange` (29 rows),
`Cmd.VolumeMute` (6), `Cmd.VolumeDecrease` (6), `Help_InsertDevice` (5),
`Cmd.SendMessage` (4). It is not a volume problem.

The high-feature rows are mostly the bypass working as designed (a real command
plus a slot value). **The 1-feature rows are the pathology**, in full:

| n | phrase | corpus label | fires |
|---:|---|---|---|
| ×2 | lying down | Default Fallback Intent | Cmd.VolumeDecrease |
| ×1 | laying down | Default Fallback Intent | Cmd.VolumeDecrease |
| ×1 | winding down | Default Fallback Intent | Cmd.VolumeDecrease |
| ×1 | calm down | Default Fallback Intent | Cmd.VolumeDecrease |
| ×1 | too funny | Default Fallback Intent | Cmd.VolumeDecrease |
| ×1 | pulling up | Default Fallback Intent | Cmd.VolumeIncrease |
| ×1 | start dreaming | Default Fallback Intent | Cmd.TranscribeStart |
| ×1 | stop beeping | Default Fallback Intent | Cmd.StreamingStop |
| ×1 | theek hai main bata dunga | Default Fallback Intent | Help_Home |
| ×1 | new feeling | Default Fallback Intent | Help_WhatsNew |
| ×1 | new variants | Default Fallback Intent | Help_WhatsNew |
| ×1 | sometime games New York | Default Fallback Intent | Help_WhatsNew |
| ×1 | Ginger mute | Cmd.VolumeMute | Cmd.VolumeMute |
| ×1 | mute Michael Jackson | Cmd.VolumeMute | Cmd.VolumeMute |
| ×1 | silence Henry | Cmd.VolumeMute | Cmd.VolumeMute |
| ×1 | unmute serenity | Cmd.VolumeUnmute | Cmd.VolumeUnmute |
| ×1 | stream iHeartRadio | Cmd.StreamingStart | Cmd.StreamingStart |
| ×1 | check check check testing testing | Help_SelfCheck | Help_SelfCheck |
| ×1 | play ringtone | Help_DeviceSettings | Cmd.ListenMessage |
| ×1 | 14 volume | Cmd.VolumeIncrease | Help_Volume |
| ×1 | cartoon volume | Cmd.VolumeIncrease | Help_Volume |

Note the three-way split. Rows 1-12 are labelled `Default Fallback Intent` by QA and
fire anyway — false positives. Rows 13-18 are labelled as commands and the engine
gets them **right**: `mute Michael Jackson` is genuinely a mute request. Rows 19-21
are labelled as commands and fire the *wrong* one (`play ringtone` →
`Cmd.ListenMessage`, `cartoon volume` → `Help_Volume`). **One mechanism produces all
three outcomes.** That is why this cannot be fixed by tightening a threshold in
isolation, and why the measurement in §6 goes the way it does.

`theek hai main bata dunga` — Hindi, in an English-only pack — reaching `Help_Home`
is the clearest illustration that the engine has no way to say "I did not understand
any of this".

---

## 4. There are two distinct defects here, and they need different fixes

This is the most important distinction in the document, and the easiest one to get
wrong.

**Defect A — OOV-exempted degenerate vectors.** `sit down`, `calm down`,
`slow down`, `settle down`, `hurry up`, `hands up`, `mute swan`. One surviving
feature, OOV ratio 0.50-0.67, confidence >= 0.97 so the guard stands down.
**This is an engine defect.** The engine has the information it needs — it knows the
feature count and it knows the ratio — and throws it away.

**Defect B — genuine model behaviour on fully in-vocabulary phrases.**
`speak up`, `back down`, `lie down`, `write it down`, `get down`, `keep it down`,
`quiet down`, `stand up`. **OOV ratio 0.00.** Every word is in the vocabulary. The
OOV guard was never going to run and the bypass is irrelevant. Only training data
moves these.

**A fix to the bypass condition addresses 6 of the 14 acting phrases. The other 8
are training-data problems.** Any plan that claims the engine change fixes "the
`down` problem" is wrong.

### 4.1 What the training data actually contains

Measured on `language_packs/en/train.csv` (8,430 rows), counting rows by the feature
set they reduce to under the shipped vocabulary — which is what the model is really
trained on, not the raw string:

| feature set | rows | labels |
|---|---:|---|
| `['mute']` | 1 | `Cmd.VolumeMute` (the literal row `mute`) |
| `['silence']` | 1 | `Cmd.VolumeMute` (`silence`) |
| `['stream']` | 1 | `Cmd.StreamingStart` (`stream`) |
| `['unmute']` | 1 | `Cmd.VolumeUnmute` |
| `['up']` | 1 | **`Default Fallback Intent`** (`i'm up`) |
| `['down']` | **0** | — |

Two findings, and they point in opposite directions.

**`mute` / `silence` / `stream` are deliberate.** Somebody decided a bare command
word should work, and trained it. The degenerate vector for those words is
*correct by design*. The collapse in §1 is what makes `mute swan` inherit it. So:

> As long as the featuriser silently drops `swan`, you cannot have bare `mute` work
> and `mute swan` not work **from the model alone**. The two are the same input.
> Only something outside the model — something that can still see that a token was
> discarded — can separate them. That is exactly what `oovRatio` is, and exactly
> what the bypass currently switches off.

`mute` has an OOV ratio of 0.00; `mute swan` has 0.50. The information needed to
split them is present and unused.

**`down` and `up` are not deliberate.** There is no training row that reduces to
`['down']` at all, and the one that reduces to `['up']` is labelled
`Default Fallback Intent`. Bare `down` → `Cmd.VolumeDecrease` at 0.9998 is therefore
**extrapolation onto an input the training distribution never contained** — the
coefficient column for `down` was learned entirely from longer volume phrases, and
scoring a unit vector on that column alone is not a prediction the model was ever
fitted to make. The 0.9998 is an artifact of the geometry, not evidence. And the one
counterexample that does exist (`i'm up` → fallback) is outweighed to the point of
invisibility.

For reference, `down` appears in 150 training rows: 88 `Cmd.VolumeDecrease`,
27 `Default Fallback Intent`, 16 `Help_Volume`, the rest scattered. So negative
examples *do* exist — but every one of them is a long sentence
(`ashes to ashes all fall down`, `walking down`, `i was down 17 grand earlier today`,
and their `can you` / `please` augmentation variants). Not one is a short
particle-verb phrase, so not one of them teaches anything about the one-feature
vector. **The gap is not "no negatives"; it is "no negatives at the length where the
failure happens".**

---

## 5. Exposure — how a bystander utterance reaches the engine

Established from code, not assumed. There is **no wake word or hotword anywhere in
the package** (no `wake`/`hotword` symbol exists). Activation is host-driven:

- `VoiceIntentSession.start()` (`:193`) opens the microphone. The host decides when —
  typically a button.
- `didReceiveFinalResult` (`:709`) classifies **every** final transcript, guarded only
  by `state != .speaking` (our own TTS) and `started`.
- `handleTurnAdvance()` (`:578`) decides what happens after a turn:
  - `awaitingAnswer == true` → `resumeListening()` **unconditionally**,
  - else if `!config.autoStopOnSilence` → `resumeListening()` (continuous mode),
  - else → `.idle`, mic off.

So the exposure window is:

1. **Continuous mode** (`autoStopOnSilence == false`): the mic is open across turns
   and every utterance in the room is classified. The package default is `true`
   (`VoiceIntentTypes.swift:145`) and `PackageVoiceView`/`PVAViewModel` set `true` —
   but `LiveTranscriptionViewModel.swift:42` defaults to **`false`**, and
   `LiveTranscriptionView.swift:166` exposes it as a user toggle. Continuous mode is
   shipped and reachable.
2. **Any follow-up question, in either mode.** After a prompt the mic reopens
   regardless of `autoStopOnSilence`. During that window, if the awaited slot is a
   closed enum, `NLUEngine.swift:428` runs the VIK-038 topic-switch probe at
   `interrupt = 0.68`. `down` scores 0.9998, so a bystander's "sit down" does not
   merely get misread as the answer — it **cancels the user's in-progress flow and
   changes the volume**.

This is not an always-on hot-mic claim. It is: within any open-mic window the product
already has, ordinary English acts on the device.

---

## 6. What was measured for the engine-side fix

Candidate changes to the bypass condition, on the honest holdout (n=1470,
iOS-faithful ladder). "Wrong actions" uses the `wrong_action_harness` predicate — a
state-changing intent fired where the gold label was something else.

| variant | accuracy | wrong actions | Δ accuracy |
|---|---:|---:|---:|
| **base** (shipped) | 1346 (91.56%) | 7 | — |
| bypass also requires `features >= 2` | 1343 (91.36%) | **6** | −3 |
| bypass also requires `features >= 3` | 1342 (91.29%) | **6** | −4 |
| `oov_bypass` 0.97 → 0.90 | 1348 (91.70%) | 7 | +2 |
| `oov_bypass` 0.90 + `features >= 3` | 1343 (91.36%) | **6** | −3 |

Effect on the degenerate probes:

| phrase | base | `features >= 2` |
|---|---|---|
| mute Michael Jackson | Cmd.VolumeMute | Default Fallback Intent |
| Ginger mute | Cmd.VolumeMute | Default Fallback Intent |
| mute swan | Cmd.VolumeMute | Default Fallback Intent |
| stream Netflix | Cmd.StreamingStart | Default Fallback Intent |
| stream iHeartRadio | Cmd.StreamingStart | Default Fallback Intent |
| transcribe Beethoven | Cmd.TranscribeStart | Default Fallback Intent |
| send a message to john | Cmd.SendMessage | Cmd.SendMessage ✅ |
| volume up | Cmd.VolumeIncrease | Cmd.VolumeIncrease ✅ |
| mute my hearing aids | Cmd.VolumeMute | Cmd.VolumeMute ✅ |

**The honest read.** `features >= 2` costs 3 holdout rows net and removes one
wrong action. The net hides the shape, so here are the rows it actually moves:

*Lost* (base right, `features >= 2` wrong):

| row | gold | becomes |
|---|---|---|
| `retrieve phone` | Cmd.FindMyPhone | Default Fallback Intent |
| `its lowd` | Cmd.VolumeDecrease | Default Fallback Intent |
| `i need instructions` | Help_Home | Default Fallback Intent |
| `audio redirection` | Cmd.StreamingStart | Default Fallback Intent |

*Gained*: `play festival` (gold `Default Fallback Intent`) stops firing
`Cmd.ListenMessage`.

Note what the four losses are. They are **not** commands with a slot value — the case
the bypass was written for. They are short commands containing one rare or
**misrecognised** word: `lowd` for "loud", `redirection`, `retrieve`. The bypass has
been quietly doing a second job nobody wrote it for — rescuing ASR mangling — and
tightening it forfeits part of that rescue. That is a real cost and it will be felt
by users with accented or quiet speech, which in a hearing-aid product is not a
marginal population.

So the trade is: **four short mis-heard commands go to fallback, and a class of
bystander utterances stops acting on the device.** It does not pay for itself on the
accuracy column and it will not, because the holdout scores a needless repeat and a
wrong device action as one row each. The asymmetry is the argument — a fallback on
`its lowd` costs a repeat; `calm down` turning a hearing aid down costs a person
their hearing mid-conversation — and it is the same limitation recorded in §13.9 of
the VIK-055 plan: **the corpus cannot score the benefit.** The decision belongs to
the cost model, not to the accuracy column, and it should be taken by a named owner
rather than inferred from the table.

If the four losses are judged unacceptable, the next thing to try is the second form
in §9 A.1 — require that the surviving feature not be the predicted class's single
strongest token, which is a narrower test than a raw feature count. **That variant
has not been measured.** It is listed as the next experiment, not as a
recommendation; whether it keeps `retrieve phone` and `audio redirection` is an open
question, not a claim.

Lowering `oov_bypass` to 0.90 is the opposite trade: +2 accuracy, no safety benefit,
and it makes §3 strictly worse by standing the guard down *more* often. It is listed
here so nobody proposes it later as "the cheap win".

---

## 7. A related dead guard

`PackTFIDFVectorizer.producesNoFeatures(_:)` (`:173`) handles the n=0 case — an
utterance where *nothing* is in the vocabulary. Its own docstring says a caller
"must route these to the out-of-scope intent rather than trusting the score".

**It has no caller.** Repo-wide grep returns only the definition.

Measured impact today: **none**, by luck. With an all-zero vector every logit
collapses to its intercept, and for this pack the resulting argmax is
`Default Fallback Intent` at 0.877 — so the engine reaches the right answer for the
wrong reason. The QA corpus has 145 distinct phrases (163 rows) with zero features
(`4`, `resume`, `Seafood`, `9:37 a.m.`, `bleeding`, …) and every one of them lands
on fallback.

This is not a defect to fix under pressure, but it is a **retrain hazard**: nothing
pins the fallback intercept to the top of the list, and the day a retrain moves it,
every unrecognisable utterance in the language starts firing one fixed intent at
0.877 with no guard in the path. Either wire the helper up or delete it; leaving a
documented safety check uncalled is the worst of the three options.

---

## 8. Cross-runtime position

Checked in code, in all three repos:

| runtime | OOV guard | bypass | where |
|---|---|---|---|
| Python (reference) | yes | `oov_bypass_confidence` | `packages/runtime/nlu_engine/engine.py:1285` |
| iOS | yes | `pack.policies.thresholds.oov_bypass` | `VoiceAIKit/.../NLUEngine.swift:663` |
| **Android** | **none** | — | — |

Android's `NluConstants.REQUIRED_THRESHOLDS` is `listOf(confidence, agreement)` —
it reads no other threshold key, and `oov` does not appear in any `.kt` file in the
module. Android therefore has no ratio check at all: `mute swan` fires there with
nothing in the path, and so does `help me find a paper`, which the ratio guard
catches on iOS and Python.

So this is **not** an iOS-only defect and **not** a case where Android is ahead.
iOS and Python share a guard whose exemption is mis-specified; Android is missing the
guard entirely. Android's absence is already tracked as **VIK-059**; the
mis-specification is **VIK-073**. Both live in
`VoiceAIKit/docs/things-to-pull-from-android.md`.

**Ordering matters between them.** VIK-059 ports the guard to Android. If it ships
first, Android inherits the defect along with the feature. **Fix the condition
(VIK-073) before porting it (VIK-059).**

---

## 9. Recommendation, by artifact

Ordered by what the evidence supports, not by ease.

### A. Engine — `NLUEngine` / `PackIntentClassifier` (VIK-073)

1. **Make the bypass require a non-degenerate vector.** The bypass should stand the
   guard down only when the confidence is high *and* the utterance actually carried
   enough signal for that confidence to mean something. The measured candidate is
   `features >= 2` (§6). A narrower test worth trying next — "at least one surviving
   feature is not the predicted class's single strongest token" — is **unmeasured**;
   it is the next experiment, not a recommendation.
   Either form needs the vectoriser to expose the non-zero feature count. It does
   not today, and `vectorize(_:)` already computes it as `counts.count`.
2. **Carry the decision into the log line.** The `decide` log currently reports
   model/arbitration/final/conf/bar. It should also carry `features` and `oov`, so
   that a QA report can distinguish Defect A from Defect B without a simulator.
   This is the cheapest item on the list, and the lack of it is the only reason §4
   needed a simulator to establish.
3. **Do not ship 1 without the measurement in §6 in the commit message.** It is
   accuracy-negative and a future reader will otherwise revert it — exactly the
   failure mode that `arbitration_holdout.py` was written to prevent.

### B. Training data — `language_packs/en/train.csv`

4. **Defect B is only fixable here.** Add SHORT negative
   (`Default Fallback Intent`) examples for the particle-verb senses:
   `sit down`, `calm down`, `slow down`, `settle down`, `lie down`, `lying down`,
   `write it down`, `keep it down`, `quiet down`, `get down`, `back down`,
   `speak up`, `hurry up`, `hands up`, `pulling up`, `winding down`.
   Length matters (§4.1): the 27 existing `down` negatives are all long sentences
   and none of them constrains the one- and two-feature region where the failure
   lives.
5. **`quiet down` is the priority row**, for the reason in §3.1.
6. **Decide explicitly whether bare `down` / `up` should be commands at all.** No
   training row makes them commands today (§4.1); the behaviour is extrapolation.
   If they should be, train them and accept the collapse in §1 as the price. If they
   should not, a short negative row for each is the single cheapest fix in this
   document.
7. **Re-measure §6 after the retrain.** The bypass trade may change sign once the
   model stops being certain about bare particles — that is the outcome to aim for.

### C. Pack content — `language_packs/en/platform.yaml`

8. **Do not change `oov_bypass` as a workaround.** §6 shows the only threshold move
   available (0.97 → 0.90) makes this worse. The condition is wrong, not the number.
9. Do not hand-edit `pack-en-v1.0.54`; it is signed. Everything goes through the
   compiler.

### D. Product decision — host integration

10. **Decide whether continuous mode should exist as a user toggle** while §3.1
    stands. `LiveTranscriptionView.swift:166` exposes it; the consequence is that 13
    ordinary English phrases change device state. This is a product call, not an
    engineering one, and it should be made explicitly rather than inherited.
11. **State-changing intents reached via a topic-switch probe deserve a higher bar
    than `interrupt = 0.68`.** Cancelling a flow the user started, on a bystander's
    utterance, is the worst outcome in §5 and the cheapest to gate.

### E. QA corpus

12. The corpus already contains the evidence (§3.2) and labelled it correctly — the
    12 `Default Fallback Intent` rows that fire are honest QA labels. The gap is that
    nothing runs them as a *safety* suite. Add a bystander-phrase sheet distinct from
    the intent sheets, scored on "did the device act", not on accuracy.

### F. Investigation still open

13. Whether the same collapse reaches the slot resolver — an unknown token that is
    dropped by the featuriser is still present in the raw text the slot extractor
    reads, so intent and slots may disagree about what the sentence contained. Not
    measured.

---

## 10. Reproduction

Engine behaviour is reproducible in the test target with
`VoiceAIKit/Tests/VoiceAIKitTests/PhraseReport.swift` — set `PhraseScope.selected`
and run; it prints each phrase with its model verdict, confidence and final outcome.

The feature-count and OOV-ratio columns in this document are not available from the
harness today (see §9 A.2); they came from an iOS-faithful simulator built for this
audit: full head weights + `temperature_coreml_full` + the iOS unigram vocabulary,
validated to reproduce device output for every miss in the `Cmd.VolumeMute` report.

## 11. Caveats

- The simulator routes a zero-feature utterance to fallback directly; the shipped
  engine reaches the same answer via the intercept argmax (§7). The two agree today
  for this pack, and the 79-row count in §3.2 is unaffected because those rows all
  have ≥1 feature.
- Keyword arbitration (VIK-055) is in the path and is modelled, but no phrase in
  §3.1 hits a keyword rule — these are pure model decisions.
- The holdout is `language_packs/en/holdout_honest.csv`, n=1470, the same corpus the
  VIK-055 measurement used. Comparisons across the two documents are therefore valid.
- §3.1's 18 phrases were chosen by hand, not sampled. They are an existence proof,
  not a rate. §3.2 is the rate.
