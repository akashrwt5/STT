# QA, data-based: making `Cmd.VolumeIncrease` stable

**Scope:** one intent — `Cmd.VolumeIncrease` — measured against the QA phrase
corpus, both directions (does it fire when it should, and does it fire when it
should not).
**Corpus:** `VoiceAIKit/Tests/VoiceAIKitTests/Fixtures/help_intent_phrases.json`
— 5,411 rows, 41 labels, 1,842 distinct phrases.
**Pack:** `pack-en-v1.0.54`.
**Ladder:** the shipped three-way arbitration (VIK-055).

Every number below came from running the corpus through the engine. Nothing here
is an estimate, and where a figure is approximate it says so.

---

## 0. How to read this, before anything else

### 0.1 There are two accuracy numbers and only one of them is meaningful

| | `Cmd.VolumeIncrease` |
|---|---|
| distinct phrases correct | **17 / 34 — 50.0%** |
| **rows (occurrence-weighted) correct** | **583 / 621 — 93.9%** |

The distinct-phrase number is the one a report prints by default, and it is
misleading here. The corpus carries `volume up` 347 times and
`increase volume` 158 times; it carries `cartoon volume` once. Counting them
equally says the intent is a coin flip. Counting them as they occur says it is
solid, with a long tail of rare, mostly-mislabelled junk.

**Use the occurrence-weighted number for decisions.** The distinct list is for
finding defects, not for scoring.

### 0.2 "Does not match the corpus label" is not the same as "wrong"

Of the 17 distinct misses below, **5 are cases where our answer is better than
the corpus label** and 7 more are a taxonomy gap the corpus had nowhere else to
put. Two are real defects. The corpus label is one person's reading; it is
evidence, not truth.

### 0.3 Confidence figures

Confidences quoted from the **device run** are exact. Confidences computed
locally through the Python/ONNX head differ slightly (different fitted
temperature: 0.671457 vs iOS's `temperature_coreml_full` 0.54399), and the
CoreML head drifts a little from the exported weights on top of that — a value
of 0.9660 on device reads 0.9056 locally on the same utterance.

**Labels do not drift.** `argmax` is temperature-invariant, so every "which
intent" statement here holds on device; only the decimals move. Where a
decision sits within ~0.05 of a threshold, treat it as needing a device check.

---

## 1. Recall — all 34 distinct phrases, categorised

### ✅ Correct — 17 phrases, 583 rows (93.9% of traffic)

```
volume up                     ×347   corroborated   1.0000
increase volume               ×158   corroborated   0.9999
increase the volume            ×33   corroborated   0.9993
increase my volume             ×21   corroborated   0.9881
increase hearing aid volume     ×6   corroborated   0.9963
raise volume                    ×4   corroborated   0.9968
raise the volume                ×2   corroborated   0.9925
louder                          ×2   model only     0.9996
increase the volume of my hearing aids ×2 corroborated 0.8877
increase                        ×1   model only     0.9999
could you increase my volume    ×1   corroborated   0.9966
make my volume louder           ×1   corroborated   0.9830
change up volume to max         ×1   model only     0.9987
turn my volume up               ×1   corroborated   0.9996
turn my hearing aids up         ×1   model only     0.9979
volume 100%                     ×1   model only     0.8909
TV is not broken it's just I didn't have any volume up ×1 corroborated 0.9975
```

The head of the distribution is entirely correct and mostly at ≥0.98. There is
no accuracy problem in the phrasings users actually say.

### ❌ Group A — the corpus label is wrong, our answer is right (5 phrases, 5 rows)

| phrase | corpus says | we say | note |
|---|---|---|---|
| `I never make it` | Cmd.VolumeIncrease | FALLBACK | nothing to do with volume |
| `raise the temperature in my area` | Cmd.VolumeIncrease | FALLBACK | about temperature |
| `Alexis the volume` | Cmd.VolumeIncrease | FALLBACK | ASR garbage |
| `cartoon volume` | Cmd.VolumeIncrease | Help_Volume | ASR garbage |
| `14 volume` | Cmd.VolumeIncrease | Help_Volume | ASR garbage |

**`raise the temperature in my area` deserves attention.** The model scored
`Cmd.VolumeIncrease` at **0.6691** against a 0.70 bar. It was refused by 0.03.
A hearing aid raising its volume because someone mentioned the temperature is
the kind of wrong action the budget exists to prevent, and right now the only
thing standing between us and it is three hundredths of a point. That is not a
defect to fix, but it is a reason not to lower the fire threshold.

**Action:** relabel these 5 rows in the corpus. Keeping them labelled
`Cmd.VolumeIncrease` means every future measurement scores correct behaviour as
a miss.

### ❌ Group B — the bare noun, genuinely ambiguous (2 phrases, **21 rows**)

| phrase | rows | we say |
|---|---|---|
| `volume` | 19 | Help_Volume 0.9736 → FULFILL |
| `my volume` | 2 | Help_Volume 0.9344 → FULFILL |

**This is 21 of the 38 miss-rows — over half the entire miss weight is one
ambiguous word.**

Saying "volume" is not a request to increase it. The corpus guessed
`Cmd.VolumeIncrease`; the model answers `Help_Volume` (show volume help) at high
confidence. Neither is obviously right, and acting on a guess here means
changing the user's hearing in response to a word.

**Action: product decision, not an engineering one.** Three options:

1. **Leave it** — `Help_Volume` shows the user their options. Defensible, and it
   is the current behaviour.
2. **Route to fallback** — treat a bare noun as not-a-command.
3. **Route to `Cmd.VolumeIncrease`** — requires a training row and accepting
   that "volume" changes the volume.

Whatever is chosen, it moves 21 rows, which is the single largest lever on this
intent's number. Do not fix anything else in this document expecting the
percentage to move much.

### ❌ Group C — taxonomy gap: absolute volume (7 phrases, 9 rows)

```
set volume to 40%                      set volume to default
set volume to normal              ×2   set the default volume            ×2
set volume to mid-range                set my hearing aids volume to default
auto adjust the volume
```

The pack has `Cmd.VolumeIncrease` and `Cmd.VolumeDecrease`. **Both are
relative.** There is no intent for "set the volume to a value". The corpus put
these under `Cmd.VolumeIncrease` because there was nowhere else to put them.

This is not a model failure or a code failure. **The taxonomy has a hole.**

**Action:** product decision — either add a `Cmd.VolumeSet` intent (with a level
slot), or rule that absolute-volume requests route to `Help_Volume`, and add
training rows accordingly. Until then these will keep scoring as misses however
the model is tuned.

### 🔴 Group D — DEFECT: a wrong action (1 phrase, 2 rows)

```
set volume to normal   ×2   →   Cmd.VolumeUnmute   →   FULFILL
                                device 0.9660 · local 0.9056
```

**This is the only wrong ACTION in the entire intent.** Every other miss lands
on fallback or help, which change nothing. This one unmutes the device when the
user asked to set a level.

Traced: no keyword rule fires, the model alone answers `Cmd.VolumeUnmute` with
high confidence, no guard applies, it clears the bar and fires.

**Action:** training data. `set volume to normal` needs to exist as a labelled
row for whatever Group C decides, so the model stops reading "normal" as
"unmute". **Highest priority item in this document** — it is the only one that
does something to the device.

### ❌ Group E — DEFECT: a real miss (1 phrase, 1 row)

```
make volume full   →   Cmd.VolumeIncrease 0.5535 (device) / 0.5080 (local)   →   FALLBACK (bar)
```

A genuine volume-up request. The model reads it correctly but is not confident
enough, and **no keyword rule catches it**:

```
\bvolume\b.{0,10}\b(up|higher|louder)\b       ← "full" is not in the list
```

**Action: one-word pack change.** Extend that alternation:

```
\bvolume\b.{0,10}\b(up|higher|louder|full|max|maximum)\b
```

Sibling phrasings already work — `change up volume to max` (0.9987) and
`volume 100%` (0.8909) — so this is a gap in one alternation, not a family
failure. Verify against `Cmd.VolumeDecrease` before shipping: `volume minimum`
appears in that sheet, and the mirror rule has the same shape.

### ⚖️ Group F — arbitration, working as designed (1 phrase, 1 row)

Read these two rows together. They are the same shape — long rambling speech
with a command phrase buried in it — and they land on opposite sides:

```
"I'm surprised that wasn't part of the setup I guess we don't do that
 anymore increase volume"
      keyword Cmd.VolumeIncrease · model Default Fallback 0.7072
      → CONTESTED → 0.60 → FALLBACK        (scored as a MISS)

"TV is not broken it's just I didn't have any volume up"
      keyword Cmd.VolumeIncrease · model Cmd.VolumeIncrease 0.9975
      → CORROBORATED → FULFILL             (scored as a match)
```

The only difference is whether the model recognises anything. That is exactly
the discriminator VIK-055 is built on, visible in production data.

**The first row is scored as a miss, and that is the measurement problem, not a
behaviour problem.** `VoiceAIKit/docs/VIK-055-keyword-arbitration-plan.md` §13.9
predicted this: a corpus whose out-of-domain rows are not labelled out-of-domain
measures the *cost* of arbitration and never its *benefit*.

**Action:** none to the code. When relabelling (Group A), consider whether this
row is really `Cmd.VolumeIncrease` or is really out-of-scope.

---

## 2. Precision — what wrongly BECOMES `Cmd.VolumeIncrease`

The other direction, and the more important one for safety: of all 5,411 rows
across all 41 labels, which ones end up firing `Cmd.VolumeIncrease`?

**Three. Out of 5,411.** Precision is not this intent's problem.

| phrase | corpus label | how it happened |
|---|---|---|
| `how do you turn the volume up on the hearing aid` | Help_Volume | rule#9 → `.ruleOnly` → **fires** |
| `turn mute hearing aids up` | Cmd.VolumeMute | model 0.8224, no rule |
| `pulling up` | Default Fallback Intent | model **0.9979**, no rule |

`turn mute hearing aids up` is genuinely ambiguous — reasonable people disagree.

`pulling up` at **0.9979** is worth a training row: two common words, nothing to
do with volume, and the model is as certain about it as it is about
`volume up`. It is a single row in this corpus and it is not currently harmful
(nobody says "pulling up" to a hearing aid), but a confidence that high on a
phrase that unrelated says the decision boundary is in an odd place.

The first one is a real defect and has its own section.

---

## 3. 🔴 DEFECT: the help guard misses "how do **you**"

This is the most serious finding in this document.

```
"how do you turn the volume up on the hearing aid"
    rule#9 → Cmd.VolumeIncrease │ model Help_Volume 0.9067 │ .ruleOnly
    help guard: NO redirect │ → Cmd.VolumeIncrease FIRES at 1.0

"how do i turn the volume up on the hearing aid"        ← one word different
    rule#9 → Cmd.VolumeIncrease │ model Help_Volume 0.9869 │ .ruleOnly
    help guard: REDIRECTS → Help_Volume │ → Help_Volume
```

**One word — `you` instead of `i` — and the device turns the volume up instead
of explaining how to.** This is precisely the ND-14 failure the help guard was
built to prevent, still live.

### Cause

`runtime/guards.json → help_marker.markers` enumerates the question forms:

```
how\s+(to|do\s+i|does|can\s+i|is|would\s+i)\b
```

`do\s+you`, `can\s+you` and `would\s+you` are absent. So:

| phrasing | caught? |
|---|---|
| `how do i …` | ✅ |
| `how to …` | ✅ |
| `how can i …` | ✅ |
| `how would i …` | ✅ |
| **`how do you …`** | ❌ |
| **`how can you …`** | ❌ |
| **`how would you …`** | ❌ |

The corpus carries **13 rows** phrased `how do/can/would you …`, three of them
`Help_Volume`:

```
how do you change the hearing aid volume        → Help_Volume  (model saved it, 0.9336, no rule fired)
how do you adjust the volume on hearing aid     → Help_Volume  (model saved it, 0.9715, no rule fired)
how do you turn the volume up on the hearing aid → Cmd.VolumeIncrease  ← FIRES
```

Only the third one contains a phrase rule#9 claims. The other two are saved by
accident — no rule fires, so the model's `Help_Volume` stands. **The guard is
not what protects them.**

### Note on the ladder, stated honestly

Under the previous two-way arbitration this turn would have been `contested`
(rule says increase, model says Help_Volume) → 0.60 → fallback: wrong, but
harmless. Under three-way it is `.ruleOnly` and **fires**. Under the pre-VIK-055
bypass it also fired.

So three-way restores the old behaviour here, and two-way's accidental block is
not an argument for two-way — it blocked this by refusing every rule the model
disagreed with, which cost nine correct turns elsewhere (VIK-055 §13.4). **The
right fix is the guard, because the model already knows: it answers
`Help_Volume` at 0.9067.** The guard is the mechanism designed to let it win.

### Action

Add the missing forms to `help_marker.markers`:

```
how\s+(to|do\s+(i|you)|does|can\s+(i|you)|is|would\s+(i|you))\b
```

**Pack change, no code change.** Then verify:

1. `how do you turn the volume up on the hearing aid` → `Help_Volume`
2. All 13 `how do/can/would you` rows — 8 are `Default Fallback Intent` and must
   stay there. The marker only *redirects an intent that has a help sibling*, so
   a fallback-bound phrase is untouched — but assert it rather than assume it.
3. Re-run the full holdout: `help_marker` affects every paired command intent,
   not just volume. `wrong_action_count` must not increase.

---

## 4. Keyword rule audit — 8 of 9 rules do nothing

`Cmd.VolumeIncrease` ships **nine** keyword rules. Measured over all 5,411 rows:

| rule | rows matched | verdict |
|---|---|---|
| **#9** `\b(increase\|raise\|turn up)\b.{0,15}\bvolume\b \| \bvolume\b.{0,10}\b(up\|higher\|louder)\b \| \bturn it up\b \| \bturn up\b \| \bvolume up\b \| \bamplify\b` | **593** (578 `Cmd.VolumeIncrease`, 15 `Help_Volume`) | carries the intent |
| #10 `\b(too\|so\|very\|really)\s+(quiet\|low\|soft\|faint)\b` | 1 | **only ever fires on the WRONG label** |
| #11 `…(sounds?\|volume\|audio\|…)…(quiet\|low\|soft\|faint\|dull\|unclear)` | 0 | dead |
| #12 `…(miss\|missing\|can.?t (catch\|hear))…(words?\|speech\|…)` | 0 | dead |
| #13 `…sound like whispers…` | 0 | dead |
| #14 `…nothing coming through… \| …slipping past me…` | 0 | dead |
| #15 `…asking to repeat themselves…` | 0 | dead |
| #16 `…(sound\|seems\|feels)…(far away\|distant)…` | 0 | dead |
| #17 `…(crank\|jack\|pump\|boost\|amp)…(it\|the\|sound\|volume)…` | 0 | dead |

None of the zero-match rules is shadowed by an earlier rule — they genuinely
match nothing in 5,411 rows.

**Rule #10 is a defect.** Its single match in the whole corpus is:

```
"how to step too low"   (corpus label: Help_Health)
    → matches "too low" → claims Cmd.VolumeIncrease
    → model says Cmd.ActivityStep 0.4787 → .ruleOnly
    → help guard redirects (the phrase has "how to") → Help_Volume
    → Help_Volume's own probability is 0.0029 → below bar → FALLBACK
```

It lands on the fallback — not a wrong action — but only because the help guard
and the calibrated re-read happened to catch it. A rule whose only observed
behaviour is a false claim should not be relied on to keep failing safely.

**Action, and be careful here:** "dead on this corpus" is **not** "useless".
These eight rules encode empathetic phrasings — a user saying *"everything
sounds so faint"* rather than *"volume up"* — and this corpus simply contains
none of them. Deleting them would remove coverage nobody has measured.

The honest steps are:

1. **Fix #10.** `too low` is a real collision — `step too low`, `battery too
   low`, `too low a dose`. Narrow it to the audio context, the way #11 already
   does, or fold it into #11 and delete it.
2. **Do not delete #11–#17 on this evidence.** Instead, get the evidence: run
   them against a corpus that contains such phrasings, or confirm with product
   whether the empathetic phrasings ever shipped to users.
3. **Record the finding either way** — that eight of nine rules have never been
   observed firing is worth knowing before anyone adds a tenth.

---

## 5. What is NOT broken — do not "fix" these

- **The core phrasings.** `volume up`, `increase volume`, `increase the volume`,
  `increase my volume` — 559 rows, all correct, all ≥0.98.
- **Precision.** 3 false positives in 5,411 rows.
- **The fire threshold.** It is what refuses `raise the temperature in my area`
  (0.6691) and `make volume full` (0.5535). Lowering it to catch the second
  would admit the first. Group E is fixed with a rule, not with the bar.
- **Arbitration.** 11 corroborated, 1 contested, 0 rule-only among the 34
  phrases. Rule and model agree on this intent almost always, which is why
  VIK-055 was low-risk here.
- **The agreement bar.** No `Cmd.VolumeIncrease` phrase in this corpus sits in
  the `[0.50, 0.70)` corroborated band, so the bar neither helps nor hurts here.

---

## 6. Actions, in priority order

| # | Action | Type | Effort | Why this order |
|---|---|---|---|---|
| 1 | Fix `help_marker.markers` — add `do you`, `can you`, `would you` | **pack** | S | The only defect that makes the device act on a question. §3. |
| 2 | Training row for `set volume to normal` (and the Group C family) | **data** | M | The only other wrong ACTION. §1 Group D. |
| 3 | Narrow or fold rule #10 (`too low`) | **pack** | S | Its only observed firing is a false claim. §4. |
| 4 | Add `full\|max\|maximum` to rule #9's second alternation | **pack** | S | Fixes `make volume full`. Check the `Decrease` mirror. §1 Group E. |
| 5 | Decide what bare `volume` means | **product** | M | 21 rows — the largest single lever on the number. §1 Group B. |
| 6 | Decide whether `Cmd.VolumeSet` exists | **product** | L | 9 rows, and #2 depends on the answer. §1 Group C. |
| 7 | Relabel 5 mislabelled corpus rows | **corpus** | S | Otherwise correct behaviour keeps scoring as failure. §1 Group A. |
| 8 | Training row for `pulling up` | **data** | S | 0.9979 on an unrelated phrase. §2. |
| 9 | Establish whether rules #11–#17 ever fire | **investigation** | M | Eight unmeasured rules. §4. |

Items 1, 3 and 4 are pack edits with no code change and can ship together in one
pack revision. Items 2, 5, 6 need a decision before any data work starts.

**Gate for any of them:** re-run the holdout
(`scripts/analysis/arbitration_holdout.py`) and the wrong-action harness.
`wrong_action_count` (currently 5) must not increase. Items 1 and 3 touch the
help guard and rule table globally — they affect every paired command intent,
not only volume.

---

## 7. Reproducing every number here

```bash
# The report that produced §1 (device-accurate confidences)
#   edit PhraseScope.selected = .intent("Cmd.VolumeIncrease")
#   in VoiceAIKit/Tests/VoiceAIKitTests/PhraseReport.swift, then run the suite.
#   It writes a TSV and prints its path.

# §2 precision, §4 rule audit, §3 traces — through the reference ladder
cd IntentClassifier
REPO=$PWD BUNDLE=<path>/nlu_pack \
  python3 scripts/analysis/arbitration_holdout.py
```

---

## 8. Caveats, stated plainly

- **One intent.** Everything here is `Cmd.VolumeIncrease`. `Cmd.VolumeDecrease`
  is its mirror, shares rule shapes, and has **not** been audited. Item 4
  explicitly requires checking it.
- **One corpus.** 5,411 rows of QA data. It contains no out-of-scope rows that a
  keyword rule claims, so it cannot score the benefit of arbitration
  (VIK-055 §13.9), and it contains none of the empathetic phrasings rules
  #11–#17 target.
- **Corpus labels are evidence, not truth.** At least 5 rows in this intent are
  mislabelled, and the Group C family is labelled by necessity rather than by
  meaning.
- **Local confidences are approximate** (§0.3). Labels are exact.
- **This is a snapshot** of `pack-en-v1.0.54` with the VIK-055 three-way ladder.
  Any pack or ladder change invalidates the decimals; re-run before citing them.

---

## 9. Summary — what to change, and exactly where

Everything above, reorganised by **the artifact that changes**. That is the
axis that matters: each group has a different owner, a different build step, a
different way of being wrong, and a different blast radius. Nothing in this
intent is fixed by editing Swift.

> **Do not edit the shipped pack.** `VoiceAIKit/Sources/VoiceAISeedPackEN/packs/pack-en-v1.0.54-ios/`
> is generated and signed — `integrity/manifest.sha256` records every file by
> path, so a hand edit invalidates the signature and the loader rejects the
> pack. Every content fix below is made upstream and recompiled into a new pack
> version.

### A · Pack content — `IntentClassifier/language_packs/en/`

Three edits, all regex, all in the same tables. They ship together as one pack
revision.

| # | Change | File / key | Evidence |
|---|---|---|---|
| **A1** | Add `do you`, `can you`, `would you` to the help marker | `platform.yaml:56` → `help_marker_guard.markers` (mirrored in `nlu_schema.json → help_marker_guard`) | §3 |
| **A2** | Narrow or fold rule #10 (`(too\|so\|very\|really)\s+(quiet\|low\|soft\|faint)`) into #11's audio context | `platform.yaml:70` → `keyword_triggers`, the `Cmd.VolumeIncrease` entry | §4 |
| **A3** | Add `full\|max\|maximum` to rule #9's second alternation | same table, same intent | §1 Group E |

**A1, concretely:**

```
- how\s+(to|do\s+i|does|can\s+i|is|would\s+i)\b
+ how\s+(to|do\s+(i|you)|does|can\s+(i|you)|is|would\s+(i|you))\b
```

**A3, concretely:**

```
- \bvolume\b.{0,10}\b(up|higher|louder)\b
+ \bvolume\b.{0,10}\b(up|higher|louder|full|max|maximum)\b
```

**Which file is the authoring entry point — confirm before editing.**
`nlu_compiler/content_bundle.py` reads `language_packs/<lang>/nlu_schema.json`
(lines 910, 1027) to build the bundle. `nlu_compiler/content_source.py`
round-trips the platform-owned keys between that file and
`content/platform.yaml` (lines 94, 109-110). Both currently carry identical
`help_marker_guard` and `keyword_triggers` blocks. Ask whoever owns the compiler
which one is edited by hand, change that one, and **verify the change appears in
the rebuilt bundle's `runtime/guards.json` and `keywords/en.json`** rather than
assuming the round-trip carried it.

**Blast radius — this is not a volume-only change.** `help_marker_guard.pairs`
covers eleven command intents (`Cmd.MemoryChange`, `Cmd.Streaming*`,
`Cmd.Transcribe*`, `Cmd.Translation*`, all four `Cmd.Volume*`,
`reminders.add`, `reminders.complete`). Widening the marker makes **every one of
them** redirect on phrasings they previously acted on. That is the intent, and
it is also why A1 cannot ship without a full-holdout re-run.

**Gate:** rebuild the pack, then
`scripts/analysis/arbitration_holdout.py` + the wrong-action harness.
`wrong_action_count` (currently **5**) must not increase. Report the delta per
paired intent, not just the total.

### B · Training data — `IntentClassifier/language_packs/en/train.csv`

8,431 rows today; 215 of them `Cmd.VolumeIncrease`. Each of these needs rows
added and the model retrained — a slower loop than A, and **B1 is blocked on a
product decision (C2)**.

| # | Change | Blocked by | Evidence |
|---|---|---|---|
| **B1** | `set volume to normal` and the absolute-volume family, labelled per C2 | **C2** | §1 Group D |
| **B2** | `pulling up` → `Default Fallback Intent` | — | §2 |
| **B3** | Bare `volume` / `my volume`, labelled per C1 | **C1** | §1 Group B |

**B1 is the only wrong ACTION in this intent** — `set volume to normal` unmutes
the device at 0.9660. It cannot be fixed by a keyword rule, because the failure
is the model confidently choosing `Cmd.VolumeUnmute` with no rule involved. Only
a labelled row moves it.

**B2** is not currently harmful — nobody says "pulling up" to a hearing aid —
but the model answers `Cmd.VolumeIncrease` at **0.9979** on it, which is the same
certainty it has about `volume up`. A boundary that confident on a phrase that
unrelated is worth correcting before something adjacent to it shows up in
traffic.

**Gate:** retrain, then the full holdout **and** `holdout_leakage_guard.csv` —
adding rows near an existing class boundary is exactly how leakage gets
introduced.

### C · Taxonomy and product decisions — no file, a decision

These block B, and they are not engineering calls. Until they are answered,
the corresponding rows will keep scoring as misses no matter what is tuned.

| # | Decision | Weight | Evidence |
|---|---|---|---|
| **C1** | What does bare `volume` mean? Help / fallback / increase | **21 rows** — the largest single lever on this intent | §1 Group B |
| **C2** | Does `Cmd.VolumeSet` exist (absolute level, with a slot), or do absolute requests route to `Help_Volume`? | 9 rows, and B1 depends on it | §1 Group C |

**C2 is a taxonomy hole, not a bug.** The pack has `Cmd.VolumeIncrease` and
`Cmd.VolumeDecrease`; both are **relative**. There is no intent for "set the
volume to a value", so the corpus put seven such phrasings under
`Cmd.VolumeIncrease` for want of anywhere else. Adding an intent is a pack,
training, host-action and QA change together — larger than anything else in this
document, and the reason it is a decision rather than a task.

### D · QA corpus — `VoiceAIKit/Tests/VoiceAIKitTests/Fixtures/help_intent_phrases.json`

| # | Change | Evidence |
|---|---|---|
| **D1** | Relabel 5 rows currently marked `Cmd.VolumeIncrease` | §1 Group A |

```
I never make it                    → Default Fallback Intent
raise the temperature in my area   → Default Fallback Intent
Alexis the volume                  → Default Fallback Intent   (ASR noise)
cartoon volume                     → Help_Volume or drop        (ASR noise)
14 volume                          → Help_Volume or drop        (ASR noise)
```

Also reconsider `"I'm surprised that wasn't part of the setup … increase
volume"` (§1 Group F) — it is labelled `Cmd.VolumeIncrease` and is arguably
out-of-scope. It is the row that makes correct arbitration score as a failure.

**This costs nothing and is worth doing first.** Every measurement taken before
it scores five instances of correct behaviour as defects, which is how a team
talks itself into "fixing" something that works.

### E · Investigation — no change yet, evidence first

| # | Question | Why it is not a task |
|---|---|---|
| **E1** | Do rules #11–#17 ever fire? | Zero matches in 5,411 rows, but this corpus contains none of the empathetic phrasings they target. **Deleting them on this evidence would remove unmeasured coverage.** Get a corpus that contains such phrasings, or confirm with product whether those phrasings shipped. §4 |
| **E2** | Is `Cmd.VolumeDecrease` in the same state? | It is the mirror intent, shares rule shapes, and has **not been audited**. A3 touches an alternation whose `Decrease` twin has the same structure, and that sheet contains `volume minimum`. §8 |

**E2 is a prerequisite for A3, not a follow-up.** Do not ship the `full|max`
change without checking what the mirror rule does with `minimum|min|lowest`.

### Ordering, and what actually unblocks what

```
D1  relabel corpus ─────────────────► do this first; it costs nothing and
                                      makes every later measurement honest

E2  audit VolumeDecrease ───────────► gates A3

A1 + A2 + A3  one pack revision ────► gate: holdout + wrong_action_count ≤ 5
     A1 affects 11 intents, not 1

C1, C2  product decisions ──────────► gate B1 and B3

B1 + B2 + B3  one retrain ──────────► gate: holdout + leakage guard
```

**A ships in days. B ships in weeks and only after C. D ships today.**

### The one-line version

> `Cmd.VolumeIncrease` is **93.9% correct by traffic** and its precision is
> effectively perfect — 3 false positives in 5,411 rows. It has **two real
> defects**: a help-marker gap that makes the device raise the volume when asked
> *"how do you turn the volume up"* (**A1**, pack, small), and a model confusion
> that unmutes the device on *"set volume to normal"* (**B1**, training data,
> blocked on a taxonomy decision). Everything else in the miss list is corpus
> mislabelling, an ambiguous bare noun, or a missing intent — and the headline
> "50%" figure is an artifact of counting rare phrases equally with common ones.
