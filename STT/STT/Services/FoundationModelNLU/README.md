# FoundationModelNLU — How It Works

A file-by-file guide to the Foundation Models intent classification sample.
Plan and rationale: [`docs/FM_SAMPLE_PLAN.md`](../../../../docs/FM_SAMPLE_PLAN.md).

## The one-paragraph version

When the user picks **FM** on the landing screen and speaks, the existing app
does everything it always does — captures audio, transcribes it, manages the
conversation, fills slots, speaks responses. Exactly **one** piece is swapped:
instead of the CoreML cascade deciding "which of our 60 intents is this?",
the question is put to Apple's on-device Foundation Model, which must answer
by picking a case from a fixed Swift enum. Everything in this folder exists
to ask that one question well, safely, and measurably.

## The flow of a single turn

```
You say: "turn it up a bit"
    │
    ▼
Speech pipeline (existing app code — not this folder)
    transcribes → "turn it up a bit"
    │
    ▼
NLUEngine (existing) asks its classifier: classifyAsync("turn it up a bit")
    │  In FM mode, "its classifier" is FMIntentClassifierService,
    │  because FMNLUEngineFactory wired it in at session start.
    ▼
FMIntentClassifierService
    sends the utterance to the on-device Foundation Model session,
    whose instructions (built by FMPromptBuilder) list all 60 intents.
    Guided generation forces the answer into FMClassificationOutput —
    the model CANNOT reply anything except one FMIntent case + a rating.
    │
    ▼   e.g. intent = .volumeUp, confidence = 0.95
Converts that to the app's normal ClassificationResult
    label = "Cmd.VolumeIncrease" (via FMIntent.label)
    │
    ▼
NLUEngine (existing) takes over again:
    slot filling / confirmation / fulfillment → TTS speaks "Volume increased"
```

The key idea: **this folder only answers "which intent?" — everything before
and after that question is the existing app, untouched.**

---

## What each file does

### `FMAvailability.swift` — "can this device even do this?"

Apple's on-device model only exists on Apple Intelligence-capable hardware
(iPhone 15 Pro+) with Apple Intelligence switched on. This file asks the OS
and translates the answer into a simple status the landing screen can show.

> **Example:** on an iPhone 13, `FMAvailability.status()` returns
> `.deviceNotEligible`, and the landing screen shows the FM option greyed out
> with "Requires an Apple Intelligence-capable device" — instead of a crash
> or a mystery-disabled button.

### `FMIntentSchema.swift` — the menu the model must order from

A Swift enum (`FMIntent`) with one case per production intent — 60 cases,
including `outOfScope`. Because it's marked `@Generable`, the framework
*constrains* the model's output to these cases: the model literally cannot
invent an intent that doesn't exist. Each case carries:

- `label` — the exact production string (`.volumeUp` → `"Cmd.VolumeIncrease"`),
  so the rest of the app sees the same labels the CoreML cascade produces.
- `catalogDescription` — the one-line meaning used in the prompt
  (`.changeHearingMemory` → "switch hearing-aid memory/program/preset —
  users also say environment, sound setting, scene, or mode").

> **Example:** the model wants to answer "VolumeBoost". It can't — that's not
> a case. The closest real case is `volumeUp`, so that's what comes back.

**The parity rule:** the 60 labels must exactly match
`Resources/intent_classifier_weights.json` (the production model's label
list). `STTTests/FMSchemaParityTests.swift` fails the build's test run if
anyone adds intent #61 to production without updating this enum.

### `FMClassificationOutput.swift` — the shape of the model's answer

A tiny `@Generable` struct: `intent` (an `FMIntent` case) + `confidence`
(the model's self-rating, 0–1). That's all we ask for — slots like dates and
memory names are extracted afterwards by the existing `EntityExtractor`, not
by the model.

> **Important:** the self-rating is *display-only*. Language models are
> reliably overconfident (field logs show ≈1.0 on nearly every turn), and the
> framework exposes no calibrated probability — so nothing in the app makes
> decisions based on this number.

### `FMPromptBuilder.swift` — the briefing the model reads before every turn

Builds the instruction text: what the app is, the 60-intent catalog
(generated from `FMIntentSchema`, so it can never drift from the enum),
disambiguation rules, and worked examples. The rules encode real field
lessons:

- *Command vs. question*: "turn up the volume" → `volumeUp`, but "how does
  volume work" → `helpVolume`.
- *Negation*: "I don't want to translate this" must NOT fire translation.
- *Bare fragments*: "Crowd" alone is probably an answer to a question the
  app just asked (a memory name) — classify `outOfScope` and let the
  conversation manager handle it.
- *Narration isn't a request*: "I sat at a busy cafe" describes life; it
  doesn't ask the app for anything → `outOfScope`.

A DEBUG assertion keeps the whole briefing under a token budget so it always
fits the model's context window with room to spare.

### `FMIntentClassifierService.swift` — the heart of the folder

The actual classifier. It conforms to the same `IntentClassifying` protocol
as the CoreML cascade services, which is what lets `NLUEngine` use it without
knowing or caring that an LLM is behind it.

What it does per turn:

1. Takes a **fresh, prewarmed session** (see below), sends the utterance,
   receives an `FMClassificationOutput` (guided — always valid).
2. Maps it to the app's standard `ClassificationResult`:
   - in-scope → the production label, marked so `NLUEngine` accepts it as-is
     (there is no calibrated confidence to threshold against);
   - `outOfScope` → `"Default Fallback Intent"`, which routes to the app's
     normal "Unknown" fallback card;
   - any error → same fallback shape, so a model hiccup never crashes a turn.
3. Logs the turn to `FMMetrics`.

**Why a fresh session every turn:** the framework appends every exchange to
a session transcript. In the first device run, a shared session grew per-turn
latency from 791ms to 2847ms, overflowed the context window, and — worst —
changed answers: "Change memory" classified correctly on turn 1 and as
out-of-scope on turn 3, because the model was reading the repeat against its
accumulated history. Classification needs zero history (conversation state
lives in `NLUContext`), so each turn gets a clean session, and the *next*
session is prewarmed immediately after each answer — the instruction
processing happens while the user is still talking, keeping latency flat.

### `FMNLUEngineFactory.swift` — the plug

Five lines that make everything above reachable: a factory that builds
`NLUEngine(classifier: FMIntentClassifierService())`. The existing
`LiveTranscriptionViewModel` accepts any factory, so handing it this one
swaps the classifier while inheriting the entire speech/conversation/TTS
pipeline untouched.

### `FMVoiceViewModel.swift` + `FMVoiceView.swift` — the screen

The "FM" mode UI. The view model mirrors `PVAViewModel`'s wiring (create
coordinator + live view model, start/teardown the session); the view hosts
the **existing** `LiveTranscriptionView` — same conversation UI as the other
modes — plus two FM-specific additions:

- a purple origin badge ("via Apple Foundation Model · last turn 848ms") so
  an evaluator always knows which engine answered;
- a DEBUG-only benchmark row (below).

### `FMMetrics.swift` — the flight recorder

Every classification logs one record: utterance, chosen label, self-rating,
latency, failure flag. Bounded in memory, local-only. Feeds the badge's
"last turn Nms" and the benchmark report. Filter Console.app by category
`FMMetrics` to watch turns live.

---

## `FMBenchmark.swift` — what the benchmark actually does

This is the reason the sample exists. The pitch question is "could the Apple
model replace (part of) our cascade?" — and that's answered with a number,
not an opinion.

**What happens when you tap "Run Holdout Benchmark" (DEBUG builds):**

1. **Loads the exam.** `Resources/FM/fm_holdout.csv` — a bundled copy of the
   same 341-utterance, 59-intent holdout set the production cascade is graded
   on (the one behind the 89.4% figure). Same test, same questions, no
   favoritism.
2. **Sits the model down.** Creates one `FMIntentClassifierService` and runs
   all 341 utterances through `classifyAsync`, one at a time (serial on
   purpose — realistic per-turn latency, no rate-limit pressure). Progress
   shows as "Benchmark 137/341". Expect ~5–6 minutes at ≈1s/turn.
3. **Grades it.** Each row compares the model's label to the expected label:

   > utterance: `"silence please"` · expected: `Cmd.VolumeMute` ·
   > predicted: `Cmd.VolumeMute` → **correct**
   >
   > utterance: `"i sat at a busy cafe"` · expected: `Default Fallback
   > Intent` · predicted: `Cmd.ActivityStep` → **wrong**

4. **Writes the report** (`FMBenchmarkReport`):
   - **overall accuracy** — shown on screen next to the 89.4% baseline,
     green if ≥ baseline, orange if below;
   - **per-intent accuracy** — so a weakness shows up as "Help_Battery: 2/5"
     instead of hiding inside a decent average;
   - **latency p50/p95** — typical and worst-case turn cost;
   - **device + OS stamp** — Apple updates the OS model on their schedule,
     not ours, so every report records exactly what was tested where. Two
     reports from different iOS versions are different experiments.
5. **Share button** exports the whole thing as CSV — summary block, all 341
   rows, per-intent table — ready to drop into a spreadsheet or a findings
   doc.

**The pass bars were fixed in the plan before any numbers existed** (so the
result can't be argued into whatever someone wants it to say):

- ≥ **89.4%** overall → parity with the cascade, or
- ≥ **95%** out-of-scope rejection → good enough for the fallback-tier job.

Below both → the sample is archived with its report, and the "why don't we
just use Apple's model?" question is closed with data.

**Why run it after every prompt change:** prompt edits are cheap — one line
taught the model that "environment" means memory change. But cheap edits can
regress something unrelated (that same synonym could plausibly pull "the
environment sounds harsh" — a `VolumeDecrease` phrase — toward memory
change). The benchmark is the regression net: five minutes, one number,
no guessing.

---

## Where this folder does NOT reach

- No existing file changed except one additive picker case in
  `STTTestView.swift`.
- Speech capture, endpointing, slot filling, confirmation, TTS, the
  conversation UI: all existing code, reused as-is.
- Everything here is `#if canImport(FoundationModels)`-gated and deletable
  as a unit — remove the folder and the picker case, and the app is exactly
  what it was before.
