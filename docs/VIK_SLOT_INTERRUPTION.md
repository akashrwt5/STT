# Slot-filling interruption — analysis, design, and implementation spec

**Status:** Not implemented. A working implementation was written, reviewed, and reverted on request. This document is the complete record so it can be redone deliberately.

**Code state:** `VoiceAIKit` is untouched. Nothing in this document has shipped.

**Supersedes:** `VIK_SLOT_INTERRUPT_FIX.md`, `VIK_DIALOGFLOW_CLAIM_VERIFICATION.md`, `VIK_FILL_FIRST_IMPLEMENTATION_PLAN.md` (all folded in here and deleted).

---

## 1. The bug in one screen

```
User : Set a reminder
App  : What do you want to be reminded about?
User : Need to go to walk
App  : *reminder cancelled* → "Starting walk activity."
```

The user answered the assistant's own question, and that answer cancelled the question.

**Mechanism.** `NLUEngine.handleSlotFilling` (`NLU/Engine/NLUEngine.swift:248`) runs the intent classifier on *every* slot-filling turn, **before** any attempt to fill the awaited slot:

```swift
private func handleSlotFilling(_ text: String) async -> NLUResponse {
    guard let intent = session.pendingIntent, let cfg = schema.intents[intent] else { ... }

    // ← this runs first, on every turn
    let probe = await classifier.classifyAsync(text)
    let isNewIntent = probe.label != intent
        && probe.label != schema.fallbackIntent
        && probe.label != "OUT_OF_SCOPE"
        && probe.confidence >= Self.interruptThreshold   // 0.75, hardcoded at :246
        && schema.intents[probe.label] != nil
    if isNewIntent { session.resetSlotFilling(); return .interrupted(...) }

    // ← only now does it try to fill the slot it asked for
    ...
}
```

The classifier is trained on **commands**. A slot answer is out-of-distribution input for it, and a confidence score on OOD input is not a quantity that can be thresholded.

---

## 2. Reproduction (measured, not asserted)

Run against the shipped pack's own weights: `models/intent/en/intent_classifier_weights.json`, 57 labels, `temperature = 0.822109`, vectorised per `PackTFIDFVectorizer` (sklearn tokenisation: split on non-word chars, drop 1-char tokens, unigrams + bigrams, sublinear TF-IDF, L2).

Answers to `reminders.add.ask_name` ("What do you want to be reminded about?"):

| user says | classified as | conf | today |
|---|---|---:|---|
| "Need to go to walk" | `Cmd.ActivityWalk` | 0.994 | **flow cancelled** |
| "clean my hearing aids" | `Help_CleanCare` | 1.000 | **flow cancelled** |
| "charge my hearing aids" | `Help_Battery` | 0.979 | **flow cancelled** |
| "send a message to John" | `Cmd.SendMessage` | 1.000 | **flow cancelled** |
| "turn up the volume" | `Cmd.VolumeIncrease` | 0.999 | **flow cancelled** |
| "find my phone" | `Cmd.FindMyPhone` | 1.000 | **flow cancelled** |
| "go running" | `Cmd.ActivityRun` | 1.000 | **flow cancelled** |
| "check my battery" | `Cmd.BatteryLevel` | 0.926 | **flow cancelled** |
| "start transcribing" | `Cmd.TranscribeStart` | 0.962 | **flow cancelled** |
| "pick up prescription" | `Cmd.VolumeIncrease` | 0.977 | **flow cancelled** |
| "start my workout" | `Cmd.ActivityExercise` | 0.995 | **flow cancelled** |
| "take out the trash" | `Help_InsertDevice` | 0.946 | **flow cancelled** |
| "call mom" | vacuous → out-of-scope | 0.000 | ok |
| "drink water" | vacuous → out-of-scope | 0.000 | ok |
| "my doctor appointment" | `reminders.add` | 0.684 | ok |

The interrupt threshold is 0.75. These are 0.93–1.00, not marginal.

Two aggravating factors:

- **Temperature sharpens.** `temperature = 0.822 < 1`, so logits are *divided* before softmax. Calibration was fitted for the 0.70 in-distribution gate (ECE 0.111 → 0.0126, good work); the side effect is that OOD inputs also return near 1.0. A 0.75 threshold sitting on a deliberately sharpened distribution has almost no discriminating power.
- **The flow survives only by accident.** "call mom", "drink water", "buy milk" are safe purely because they produce *no vocabulary features at all* and route to out-of-scope through the `isVacuous` path (`PackEngineFactory.swift:240`). The moment a reminder subject overlaps command vocabulary, it is gone. For a hearing-aid product, "remind me to clean my hearing aids" and "remind me to charge my hearing aids" are among the most likely reminders a user will ever set. Both are 0.98+ cancellations.

Related: `"take my medicine"` → `Cmd.VolumeDecrease` @ 0.174. Same defect, other face — the score is meaningless, it just happened to land low.

---

## 3. Provenance — this is a regression

| commit | date | what |
|---|---|---|
| — | before 2026-06-20 | `handleSlotFilling` filled the awaited slot, ran `extractAllSlots`, called `advanceSlots`. **No probe.** This case worked. |
| `13653cb` | 2026-06-20 | *"Add intent interruption handling to slot-filling (mirrors Python NLUEngine)"* — inserted the probe **at the top of the method**, ahead of the fill. **The regression.** |
| `40eebf5` | 2026-07-09 | *"created VoiceIntentKit package"* — copied verbatim into the package |
| `408d78c` | 2026-08-21 | hardcoded `"Default Fallback Intent"` → `schema.fallbackIntent`. Cosmetic. |

Nothing else has touched it in 172 commits. Live ~2.5 months.

**Two things explain the blind spot.**

*Its worked example is command-shaped.* The commit reasons from: "set a reminder" → "what to remind?" → **"change memory to Car"**, which has an imperative verb and a carrier and classifies `Cmd.MemoryChange` @ 1.000. The feature was designed and hand-checked against interruptions that *look like commands*. A plain descriptive answer scores just as high, and the threshold cannot separate them because the difference is grammatical, not one of confidence.

*It shipped with no tests.* `13653cb` touched 5 files, none a test. Across today's 142 test functions there is no interruption test — the only `.interrupted` occurrence is one enum case in an unrelated `switch` (`VoiceIntentSessionSmokeTests.swift:248`).

**Open item:** the commit claims it mirrors Python's `_handle_slot_filling`. That source (`IntentClassifier/scripts/nlu/engine.py`) is not in this repo or its history, so the ordering was never checked against it. **Confirm this.** If Python fills first and probes second, this is purely a porting error and the server side is fine. If Python also probes first, the same bug is live there.

---

## 4. Why no classifier-based rule can fix the open slot

This was tested, not assumed. Two candidate rules were built and measured.

### Candidate A — command-frame (imperative verb) detector

`^\s*(please\s+)?(change|switch|set|turn|start|stop|play|send|find|open|close|increase|decrease|raise|lower|mute|unmute|show|tell|read|pause|resume|connect|pair|load|restore|apply|use)\b`

Result on labelled ground truth: **1/10 missed interrupts, 3/16 legitimate reminders wrongly cancelled.** The false positives were "start my workout", "turn off the stove", "send the report to my boss" — all perfectly ordinary reminders.

### Candidate B — command-frame AND high confidence

| utterance | truth | frame | classifier | conf |
|---|---|---|---|---:|
| "turn off the stove" | **reminder** | YES | `Cmd.VolumeMute` | 0.552 |
| "turn up the volume" | command | YES | `Cmd.VolumeIncrease` | 0.999 |
| "start my workout" | **reminder** | YES | `Cmd.ActivityExercise` | **0.995** |
| "start transcribing" | command | YES | `Cmd.TranscribeStart` | **0.962** |
| "send the report to my boss" | **reminder** | YES | `Cmd.SendMessage` | 0.961 |
| "send a message to John" | command | YES | `Cmd.SendMessage` | 1.000 |
| "clean my hearing aids" | **reminder** | no | `Help_CleanCare` | 1.000 |
| "mute my hearing aids" | command | YES | `Cmd.VolumeMute` | 0.988 |

Rows 3–4: **the reminder scores higher than the real command.** Any threshold that catches "start transcribing" (0.962) also catches "start my workout" (0.995).

These pairs are structurally identical:

```
"turn off the stove"          vs  "turn up the volume"
"start my workout"            vs  "start transcribing"
"send the report to my boss"  vs  "send a message to John"
"clean my hearing aids"       vs  "mute my hearing aids"
```

The difference is not grammatical. It is whether the **object** is a device capability or a thing in the world — a semantic distinction. No regex, no POS tagger, no confidence threshold separates them.

**Conclusion, on data: for an open free-text slot, "is this an answer or a command?" is not solvable by classification.**

### A note on the Alexa carrier-phrase idea

An earlier draft of this analysis proposed borrowing `AMAZON.SearchQuery`'s carrier-phrase requirement. **That was a misreading and is retracted.** Amazon's carrier requirement is a *model-design-time* rule so the NLU knows where free text begins *within one utterance* ("search for {query}"). It is not a runtime disambiguator for a bare answer to a slot prompt. Candidate A above is what that idea becomes at runtime, and it fails.

---

## 5. What the industry actually does (verified against primary docs)

First, a correction to an earlier claim in this repo's notes: **`INTERRUPT_THRESHOLD = 0.75` is not a Dialogflow concept.** Neither ES nor CX documents a confidence threshold whose job is to interrupt slot filling.

### Dialogflow ES

Documented escape mechanism, verbatim:

> "When the end-user says an exit phrase like 'Cancel', 'Stop it', 'That's enough', etc., the agent replies with 'Okay, canceled' and clears slot filling contexts."

with a dedicated API field:

> "`DetectIntentResponse.queryResult.cancelsSlotFilling` field is set to `true` when slot filling is canceled."

And on slot-filling semantics, from the ES→CX migration guide:

> "These parameters are intent parameters marked as required. **The intent continues being matched until all required parameters are collected.**"

**Honest limit:** ES's docs are silent on whether another intent can match during slot filling, and the contexts doc says *"Intents with no input contexts can be matched at any time"* — so it cannot be claimed that ES blocks switching. What *is* documented is that cancellation is a first-class, built-in feature with its own response field.

### Dialogflow CX

CX **does** support interruption during form filling, scoped by declared routes. Handler evaluation order during parameter filling:

```
Phase 1 — routes with intent requirements:
            page routes → page route groups → flow routes → flow route groups
Phase 2 — routes with only condition requirements
Phase 3 — event handlers (reprompt, no-match, no-input)
```

The designer authors which intents may interrupt on a page. No route declared → that intent cannot interrupt, at any confidence.

### Both editions' thresholds do the opposite of ours

**ES — ML Classification Threshold:** *"If the highest scoring intent has a confidence score greater than or equal to the ML Classification Threshold setting, it is returned as a match. … If no intents meet the threshold, a fallback intent is matched."*

**CX — Classification Threshold:** *"If the confidence score for an intent match is less than the threshold value, then a no-match event will be invoked."*

Both are a **floor** — *below it, give up*. Our 0.75 is a **bar** — *above it, destroy the user's in-progress flow*.

| | Dialogflow threshold | VoiceAIKit's 0.75 |
|---|---|---|
| direction | below → fallback | above → interrupt |
| failure mode | nothing matched | **the user's work is gone** |
| cost of a mistake | a reprompt | flow cancelled + wrong action executed |
| input it judges | in-distribution command | **out-of-distribution slot answer** |

Same shape of number, opposite semantics. This is the most likely explanation of how `13653cb` happened: *"Dialogflow has a confidence threshold"* → *"so I'll use a confidence threshold to interrupt."*

### Alexa

Dialog Management supports context switching, but: *"you are responsible for keeping track of the filled slots when switching contexts. If you don't, the dialog will start over at the beginning instead of where the user left off."* — note that our engine calls `session.resetSlotFilling()` and discards everything.

More importantly, during `Dialog.ElicitSlot`: *"Alexa **biases the interaction model to listen for the utterances defined for the slot**."* Alexa leans toward the slot. Our engine leans the other way — the classifier runs first and does not know a slot is awaited.

And `AMAZON.SearchQuery`, Alexa's free-text slot (the analogue of our `remind`), carries structural restrictions: cannot be combined with other slot types in one utterance, only one per utterance, and **must** be used with a carrier phrase. Amazon prevents the ambiguity at model-design time rather than resolving it at runtime.

### Apple

App Intents' `requestDisambiguation(among:dialog:)`: when a parameter is ambiguous, **ask the user**. The system does not guess. Alongside `requestValue` (missing) and `requestConfirmation` (before acting).

### Summary

| platform | approach |
|---|---|
| Dialogflow ES | exit phrases, first-class, with an API field |
| Dialogflow CX | designer declares which intents may interrupt this page |
| Alexa | bias toward the elicited slot; constrain free-text slots structurally |
| Apple | ask when ambiguous, never guess |
| **VoiceAIKit today** | **classifier confidence ≥ 0.75 on OOD input** |

Four different strategies, none of which is ours.

**But do not argue this from Dialogflow.** The strongest argument is the measured data in §2 and §4: on this pack's own weights, a legitimate reminder (0.995) outscores a real command (0.962). That argument stands on its own and cannot be countered with "we can do better than Google."

---

## 6. The design: fill-first

### Principle

**The most specific evidence wins.** An exact gazetteer hit is near-certain evidence. A softmax score over out-of-distribution text is weak evidence. Today the weak signal runs first and vetoes the strong one.

Restated as a rule:

> **Ask the classifier whether the user changed topic only when the awaited slot could not accept the utterance.**

### Why this does not break real topic switches

The pack data makes the two cases structurally distinguishable. `entities/shared/content.json`:

| entity | `open` | `type` | values |
|---|---|---|---|
| `memory` | **false** | list | 38 |
| `recurrence` | false | list | 21 |
| `remind` | **true** | list | 6 (hints only) |
| `sys.date_time` | — | dynamic | parser |

A closed gazetteer yields a hard "this is not a valid value for this slot" signal. An open entity cannot.

Simulating `PackEntityExtractor.extract` (exact → synonym → Levenshtein fuzzy, `minLength 5`, `ratio 0.3`) against the classifier probe, for answers to `Cmd.MemoryChange.ask_memory_name`:

| user says | gazetteer fill | classifier probe | today | fill-first |
|---|---|---|---|---|
| "increase volume" | — none — | `Cmd.VolumeIncrease` 1.00 | interrupt | **interrupt** ✓ |
| "turn up the volume" | — none — | `Cmd.VolumeIncrease` 1.00 | interrupt | **interrupt** ✓ |
| "find my phone" | — none — | `Cmd.FindMyPhone` 1.00 | interrupt | **interrupt** ✓ |
| "what is my battery" | — none — | `Cmd.BatteryLevel` 0.97 | interrupt | **interrupt** ✓ |
| "restaurant" | `Restaurant` @1.00 | `Cmd.MemoryChange` 0.45 | fill | fill ✓ |
| "resturant" (misheard) | `Restaurant` @0.90 fuzzy | out-of-scope 0.00 | fill | fill ✓ |
| "turn on music" | `Music` @1.00 | `Cmd.VolumeUnmute` 0.87 | **interrupt — wrong** | **fill** ✓ |
| "custom two" | `Custom Two` @1.00 | `Help_MemoryOptions` 0.77 | **interrupt — wrong** | **fill** ✓ |

Every genuine topic switch still interrupts. And the reorder *repairs* two live defects: today "turn on music" unmutes the volume instead of selecting the Music memory, and "custom two" — literally a value in the gazetteer — plays a help topic instead of switching to it.

### The rule, by fill strength

| awaited slot | outcome | action |
|---|---|---|
| closed, exact/synonym hit (≥0.95) | unambiguous answer | fill, no probe |
| closed, fuzzy hit (0.60–0.90) | answer, approximate | fill, no probe |
| closed, no match | cannot be an answer | probe → interrupt as today |
| date-time, parsed | answer | fill, no probe |
| date-time, day parked, no time | **partial progress** | no probe, no value, reprompt |
| date-time, nothing parsed | cannot be an answer | probe → interrupt |
| open (`remind`) | anything is an answer | fill; only an explicit cancel escapes |

Every input this needs already exists: `Match.confidence` and `Match.isFuzzy` (`PackEntityExtractor.swift:37`), the `open` flag, `SlotResolving.isDateTime`.

### Where interruption is fired per slot, after this change

| intent | slot | entity | kind | can interrupt? |
|---|---|---|---|---|
| `reminders.add` | `name` | `remind` | **open** | ❌ never |
| `reminders.add` | `date_time` | `sys.date_time` | dynamic | ✅ if nothing parses |
| `Cmd.MemoryChange` | `memory_name` | `memory` | closed | ✅ if gazetteer misses |
| `reminders.add` | `recurrence` | `recurrence` | closed | — never awaited (`required: false`; `advanceSlots` only prompts for required slots) |

So in `pack-en`, exactly **one** slot loses immediate interruption: the reminder name.

### The residual cost, stated plainly

```
User : Set a reminder
App  : What do you want to be reminded about?
User : Change memory to Car
App  : When?                              ← becomes the reminder's name
User : Change memory to Car               ← user must repeat
App  : Okay, switching to Car memory      ← now date_time can't parse it → interrupt fires
```

One extra turn, on one slot, only when the user changes topic mid-reminder. This is the case `13653cb` was written for, and it is not solvable at that slot (§4). §8 is how the cost is actually paid down.

---

## 7. Implementation spec — the engine change

### Verified baseline (read, not assumed)

| item | location | note |
|---|---|---|
| `handleSlotFilling` | `NLU/Engine/NLUEngine.swift:248–311` | the method to replace |
| `interruptThreshold = 0.75` | `NLUEngine.swift:246` | hardcoded; pack's `thresholds.interrupt = 0.68` never read |
| `advanceSlots` | `NLUEngine.swift:313` | anchor for the end of the replaced region |
| `resolveDateTime` | `NLUEngine.swift:536` | **has side effects** — see trap A |
| `NLUEngine.init` | `NLUEngine.swift:79–105` | schema, classifier, entities, uncertain, noIdioms, carriers, trailingFunctionWords, leadingConnectors, confirmationGates, sessionID |
| engine construction | `Pack/Loader/PackEngineFactory.swift` — `NLUEngine(` | single call site |
| `SlotDef` | `Pack/Loader/DialogSchema.swift` | `name, entity, required, prompt` |
| `handle()` priority | confirmation → slotFilling → newIntent | a confirmation turn never reaches the slot path |
| cancel precedent | `ConfirmationAndSlotFlowTests.swift:358` | decline returns `.fulfill(message: pack.responses["sys.confirm.cancelled"])` |
| `sys.confirm.cancelled` | `capabilities/sys/responses/en.json` | `"Okay, I won't."` |

### Trap A — `resolveDateTime` is not pure

```swift
// NLUEngine.swift:536
private func resolveDateTime(_ text: String) -> (iso: String?, filled: Bool) {
    guard var match = entities.dateTime(in: text, now: Date()) else { return (nil, false) }
    if !match.explicitDay,
       let parked = session.partialDateTime.flatMap({ Self.parseLocalISO($0) }),   // ← READS it
       let anchored = entities.dateTime(in: text, now: parked) { match = anchored }
    if match.timeExplicit { session.partialDateTime = nil; return (match.iso, true) }   // ← WRITES
    ...
    session.partialDateTime = Self.formatLocalISO(cal.startOfDay(for: day))             // ← WRITES
    return (nil, false)
}
```

It mutates `session.partialDateTime` **and** reads it back as an anchor. Calling it once to test the fit and again to apply the value advances the parked day — the same class of bug `extractAllSlots(skip:)` exists to prevent.

**Rule: resolution runs exactly once. The apply step uses the captured value and never re-resolves.**

### Trap B — date-time partial progress

"tomorrow" (day, no time) does not fill the slot but parks the day. That is real progress. Treating it as "did not fit" would run the probe. Today it survives only by luck: "tomorrow" classifies as `reminders.add` @ 0.942, the same intent, so no interrupt fires. Another pack or language could break it.

Hence five outcomes, not three.

### The code

Add near `handleSlotFilling`:

```swift
/// What the awaited slot made of this utterance.
///
/// Resolution runs ONCE and the value is captured here. `resolveDateTime`
/// mutates `session.partialDateTime` *and* reads it back as an anchor, so
/// resolving twice (once to test the fit, once to apply it) advances the
/// parked day — the same class of bug `extractAllSlots(skip:)` prevents.
private enum AwaitedSlotOutcome {
    case filled(slot: String, value: String)
    /// Day parked, no time yet. Progress, not a failed answer.
    case progressed
    case openAccepted(slot: String, value: String)
    /// A closed entity rejected it — the only real evidence of a topic switch.
    case noFit
    /// No slot awaited. Preserves today's behaviour (probe).
    case noAwaitedSlot

    var isStructuredMatch: Bool {
        if case .filled = self { return true }
        return false
    }

    var allowsInterruptProbe: Bool {
        switch self {
        case .noFit, .noAwaitedSlot:              return true
        case .filled, .progressed, .openAccepted: return false
        }
    }
}

/// Resolve the utterance against the awaited slot. Every resolver is called
/// EXACTLY ONCE — see `AwaitedSlotOutcome`.
private func resolveAwaitedSlot(_ text: String, _ cfg: IntentDef) -> AwaitedSlotOutcome {
    guard let awaiting = session.awaitingSlot,
          let slot = cfg.slots.first(where: { $0.name == awaiting })
    else { return .noAwaitedSlot }

    if entities.isDateTime(slot.entity) {
        let parkedBefore = session.partialDateTime
        let (iso, filled) = resolveDateTime(text)
        if filled, let iso { return .filled(slot: slot.name, value: iso) }
        // Compared against `parkedBefore`, NOT a bare `!= nil`. `resolveDateTime`
        // returns early without touching `partialDateTime` when the text carries
        // no date at all — so once a day is parked, a bare nil-check would report
        // every later utterance as progress and swallow the interrupt for
        // "increase volume".
        //
        // Known limit: repeating the SAME day ("tomorrow" twice) parks an
        // identical value and reads as `.noFit`, so the probe runs. That is what
        // happens today, and on pack-en such an utterance classifies as this same
        // intent, so no interrupt fires either way.
        if session.partialDateTime != nil, session.partialDateTime != parkedBefore {
            return .progressed
        }
        return .noFit
    }

    if let value = entities.extract(slot.entity, from: text, isDirectAnswer: true) {
        return .filled(slot: slot.name, value: value)
    }
    if entities.isOpen(slot.entity) {
        return .openAccepted(slot: slot.name,
                             value: text.trimmingCharacters(in: .whitespaces))
    }
    return .noFit
}
```

Replace `handleSlotFilling` (`:248–311`) with:

```swift
private func handleSlotFilling(_ text: String) async -> NLUResponse {
    guard let intent = session.pendingIntent, let cfg = schema.intents[intent] else {
        session.resetSlotFilling()
        return await handleNewIntent(text)
    }

    let awaiting = session.awaitingSlot
    // ONCE. Everything below applies this captured outcome.
    let outcome = resolveAwaitedSlot(text, cfg)

    // 1. Explicit cancel ends the flow, in every slot. Checked AFTER a structured
    //    match so a gazetteer value can never lose to a cancel word. (pack-en has
    //    no such collision — `memory`, `recurrence` and `remind` share no surface
    //    with `negative` — this orders the two for packs that might.)
    //
    //    Without this there is NO way out of an open slot: `remind` accepts any
    //    text, so "cancel" becomes a reminder named "cancel".
    //
    //    `isCancelUtterance` is DEFINED IN §8, not here. Do not implement it as a
    //    plain equality check against `schema.negative` — that was the first
    //    version and it failed on "Leave it for now" in review. §8 has the rule
    //    that works and the injection it needs.
    if !outcome.isStructuredMatch, isCancelUtterance(text) {
        session.resetSlotFilling()
        return .fulfill(intent: intent, action: nil, parameters: [:],
                        message: cancelledMessage, confidence: 1.0)
    }

    // 2. Topic-switch probe, ONLY when the answer cannot belong to this slot.
    //    It used to run first, on every turn, ahead of any attempt to fill.
    if outcome.allowsInterruptProbe {
        let probe = await classifier.classifyAsync(text)
        let isNewIntent = probe.label != intent
            && probe.label != schema.fallbackIntent
            && probe.label != "OUT_OF_SCOPE"
            && probe.confidence >= Self.interruptThreshold
            && schema.intents[probe.label] != nil
        if isNewIntent {
            let abandoned = intent
            session.resetSlotFilling()
            let newResult = await handleNewIntent(text)
            return .interrupted(cancelledIntent: abandoned, result: newResult)
        }
    }

    // 3. Apply the captured outcome. Never re-resolve.
    //
    //    Written as two separate cases rather than one multi-pattern case
    //    (`case .filled(let n, let v), .openAccepted(let n, let v):`). That form
    //    is almost certainly valid Swift — both patterns bind two Strings — but
    //    it was never compiled, and one duplicated line is cheaper than a spec
    //    that might not build.
    switch outcome {
    case .filled(let name, let value):
        session.pendingSlots[name] = value
    case .openAccepted(let name, let value):
        session.pendingSlots[name] = value
    case .progressed, .noFit, .noAwaitedSlot:
        break
    }

    // ---- everything below is UNCHANGED from today ----

    extractAllSlots(cfg, text, into: &session.pendingSlots, skip: awaiting)

    if let awaiting {
        if session.pendingSlots[awaiting] != nil {
            session.slotAttempts = 0
        } else {
            session.slotAttempts += 1
            if session.slotAttempts >= 3 {
                session.resetSlotFilling()
                return .fallback(intent: schema.fallbackIntent, confidence: 0)
            }
        }
    }

    return advanceSlots(intent, cfg, breakdown: session.pendingBreakdown)
}
```

**Do not touch the `slotAttempts` block.** `.progressed` ("tomorrow") increments the counter today; preserving that is deliberate. Changing it is a separate decision with its own test.

### Threading the cancellation message

`NLUEngine` has no access to `pack.responses` — `NLUSchema` carries intents and lexicons, never the response catalog. Inject it.

`NLUEngine.swift:79`:

```swift
        confirmationGates: [String: ConfirmationGate] = [:],
+       /// Text spoken when a slot flow is explicitly cancelled. Defaulted so
+       /// existing callers (tests) compile unchanged; `PackEngineFactory`
+       /// supplies the pack's own `sys.confirm.cancelled`.
+       cancelledMessage: String = "",
        sessionID: String = "default"
```

with a stored `private let cancelledMessage: String` and its assignment.

`PackEngineFactory.swift`, at the single `NLUEngine(` call site:

```swift
        confirmationGates: confirmationGates(from: pack),
+       cancelledMessage: pack.responses["sys.confirm.cancelled"] ?? "")
```

### Threading the cancel phrases

The rule in §8 needs a phrase list. It is injected the same way, and it needs one
extra step because **`PackLexicon` has no such field today** — verified: `grep
cancelPhrases Pack/Schema/PackLexicon.swift` returns nothing. Until §9C.1 adds it,
the factory falls back to the `negative` list, so this change is never worse than
today's behaviour.

`NLUEngine.swift:79`, alongside `cancelledMessage`:

```swift
+       /// Whole-utterance phrases that abandon a slot flow. Falls back to the
+       /// pack's `negative` list until `lexicons/<lang>.json` ships
+       /// `cancel_phrases` (§9C.1). Lowercased, whitespace-collapsed by the
+       /// caller; matching rule is in `isCancelUtterance`.
+       cancelPhrases: Set<String> = [],
```

stored as `private let cancelPhrases: Set<String>`, and assigned with the fallback
so an empty injection never disables cancelling outright:

```swift
+       self.cancelPhrases = cancelPhrases.isEmpty ? Set(schema.negative) : cancelPhrases
```

`PackEngineFactory.swift`, same call site:

```swift
+       // `lexicon.cancelPhrases` does not exist yet — add it with §9C.1 and swap
+       // this line to `Set(lexicon.cancelPhrases ?? lexicon.negative)`.
+       cancelPhrases: Set(lexicon.negative),
```

**Both `NLUEngine` parameters are defaulted**, so `ConfirmationAndSlotFlowTests`
and any other existing construction site compile untouched.

### Behaviour delta

| flow | user says | today | after |
|---|---|---|---|
| reminder name | "Need to go to walk" | ❌ cancelled (0.994) | ✅ fills |
| reminder name | "clean my hearing aids" | ❌ cancelled (1.000) | ✅ fills |
| reminder name | "start my workout" | ❌ cancelled (0.995) | ✅ fills |
| reminder name | "send the report to my boss" | ❌ cancelled (0.961) | ✅ fills |
| reminder name | "call mom" | ✅ fills (by accident) | ✅ fills (by design) |
| reminder name | "cancel" | ❌ becomes the name | ✅ cancels |
| memory | "increase volume" | ✅ interrupts | ✅ interrupts |
| memory | "find my phone" | ✅ interrupts | ✅ interrupts |
| memory | "restaurant" | ✅ fills | ✅ fills |
| memory | "resturant" (misheard) | ✅ fills (fuzzy) | ✅ fills |
| memory | "turn on music" | ❌ unmutes volume | ✅ `Music` memory |
| memory | "custom two" | ❌ plays help topic | ✅ `Custom Two` |
| memory | "cancel" | ⚠️ 3 reprompts then abandon | ✅ cancels immediately |
| date_time | "tomorrow at 5" | ✅ fills | ✅ fills |
| date_time | "tomorrow" | ⚠️ parks day, re-asks | ⚠️ same |
| date_time | "increase volume" | ✅ interrupts | ✅ interrupts |

No row regresses.

### Performance

Today every slot turn pays a full TF-IDF vectorisation plus a CoreML predict. After the change the classifier runs only on `.noFit`/`.noAwaitedSlot` — so a successful slot answer costs nothing. The reminder happy path goes from 2 inferences to 0.

---

## 8. The cancel problem — and why the phrase list is only half an answer

### The gap

Field-tested during review: **"Leave it for now" did not cancel.** It became the reminder's name.

Two causes:

1. The match in §7 is exact equality against the pack's `negative` list.
2. That list is 12 entries and was built for **yes/no confirmation**, not cancellation:
   `cancel, do not, don't, dont, nah, negative, never mind, nevermind, no, no thanks, nope, stop`

So `"cancel that"`, `"stop it"`, `"forget it"`, `"leave it"`, `"not now"` all fail.

### Engine-side fix — matching rule

Equality is too strict; substring is unsafe (`wholeWord("no", in: "no sugar in my coffee")` is true, and that is a legitimate reminder — this is VIK-023 in another hat). The safe rule:

| phrase length | match |
|---|---|
| **one word** (`no`, `cancel`, `stop`, `nope`) | whole utterance must equal it |
| **two or more words** (`leave it`, `never mind`, `not now`) | utterance may **start with** it |

```swift
/// True when the utterance is one of the pack's cancel phrases.
///
/// One-word phrases require equality: `wholeWord("no", in: "no sugar in my
/// coffee")` is true and that is a legitimate reminder name. Multi-word phrases
/// may match as a prefix, so "leave it for now" is caught by "leave it".
private func isCancelUtterance(_ text: String) -> Bool {
    let t = text.lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    for phrase in cancelPhrases {
        if phrase.contains(" ") {
            if t == phrase || t.hasPrefix(phrase + " ") { return true }
        } else if t == phrase {
            return true
        }
    }
    return false
}
```

`cancelPhrases` is injected, defaulting to `Set(schema.negative)` so behaviour is no worse than today until the pack ships the field.

Verified: `memory` (47 surfaces), `recurrence` (55) and `remind` (7) share **no** surface with `negative`, so ordering the cancel check after a structured match is belt-and-braces, not a live conflict.

### Why the phrase list is not "hardcoding" — and why it is still not enough

Putting the list in the pack is the opposite of hardcoding. A list compiled into the engine applies English rules to every language — that is exactly VIK-001. A list in `lexicons/<lang>.json` is per-language data that ships with the pack and changes without an app release, which is why `affirmative`, `negative`, `carriers`, `fuzzyStopwords` and `trailingFunctionWords` already live there.

**But a hand-written list is inherently incomplete.** "forget about it", "actually don't", "no need", "skip that" — whatever is written, something is missed.

### The real gap: there is no cancel intent in the model

`models/intent/en/labels.json` has 57 labels. **None of them is a cancel or stop intent.** The model was never taught that a user can want out.

This is what the industry ships. From Amazon's docs on standard built-in intents:

> "You do not need to provide any sample utterances for these intents, although you can if you want to extend the intent."

`AMAZON.CancelIntent` → *cancel, never mind, forget it*
`AMAZON.StopIntent` → *stop, off, shut up*

These are **Amazon-trained intents**, not developer keyword lists — and developers may extend them with their own sample utterances. Dialogflow ES likewise ships exit-phrase detection as a built-in with its own API field.

**The classifier is the right tool for detecting "the user wants out." It is the wrong tool for "is this slot answer secretly a command."** Same model, different question: cancel phrases are short, distinctive and in-distribution; slot answers are OOD. The fix is not to remove the classifier, it is to ask it the right question.

### Two-layer answer

**Layer 1 — `cancel_phrases` in the pack lexicon.** Deterministic, fast, per-language, ships without retraining. Alexa's "extend the built-in with your own utterances" is the same idea. Covers the top ~15 phrases.

**Layer 2 — `sys.cancel` as label #58 in the trained model.** Catches what the list misses. Requires training phrases, retrain, recalibrate — compiler-team work.

Layer 1 is not wasted once Layer 2 exists: it stays as a fast deterministic path and as the per-pack override.

---

## 9. What needs to be implemented

### A. Engine (this repo) — one PR

1. `AwaitedSlotOutcome` + `resolveAwaitedSlot()` (§7)
2. `handleSlotFilling` reorder (§7)
3. `isCancelUtterance()` with the one-word/multi-word rule (§8)
4. Inject `cancelledMessage` and `cancelPhrases` from `PackEngineFactory`, both defaulted
5. Tests (§10)

No pack format change and no public API change. Existing construction sites compile
untouched because both new parameters are defaulted.

**Behaviour does change** — that is the point. §7's delta table is the full list: four
reminder-name cases stop being cancelled, two memory cases stop firing the wrong action,
and cancelling starts working. Nothing regresses, but do not describe this PR as
behaviour-neutral.

### B. Engine — separate PR

Wire the pack's `thresholds.interrupt`. `runtime/policies.json` ships `0.68`; `PackSections.swift:131` decodes it as `let interrupt: Double`; `NLUEngine.swift:246` hardcodes `0.75`; `PackEngineFactory` never joins them. `confidence` and `semantic` are joined — `interrupt` is silently dropped, which contradicts the package's own "the pack is the source of truth" design. It also means the pack currently *wants* a lower (more aggressive) threshold than the code applies.

**Keep this separate from A.** A changes *when* the probe runs; B changes *at what number*. Shipped together, a regression cannot be attributed.

### C. Pack / compiler team

1. **`cancel_phrases` in `lexicons/<lang>.json`** — new field, new `PackLexicon` property. English starting set:
   `cancel, cancel that, stop, stop it, that's enough, never mind, nevermind, forget it, forget about it, leave it, leave that, not now, no need, skip it, skip that, don't bother, drop it`
   Note `runtime/policies.json` and `lexicons/en.json` are both in `integrity/manifest.sha256`, so any pack edit needs a recompile and re-sign.

2. **`sys.cancel` as label #58** with training phrases, retrained and recalibrated. Engine treats it like any other intent: matching it during slot filling cancels the flow.

3. **Optional, longer term — per-slot interrupt scope** (Dialogflow CX's model). Add `interrupts` to a slot in `workflows.json`:

   ```json
   { "name": "name", "entity": "remind", "required": true,
     "prompt": "reminders.add.ask_name",
     "interrupts": [] }
   ```

   Compiler default: closed entity → all intents; open entity → `[]`. This removes the extra turn in §6 without any ML.

   **Caveat, measured:** the allowlist must be chosen from intents that never collide with plausible reminder subjects. On this pack, `Cmd.VolumeIncrease` is unsafe — "pick up prescription" scores 0.977 on it. `Cmd.MemoryChange` (1.000) and `Cmd.FindMyPhone` (1.000) were the top label for **no** reminder subject among 22 tested, at any score.

   `Cmd.VolumeMute` looks safe at the current threshold but is **not** unconditionally safe: it is the top label for "turn off the stove" at 0.552 — below 0.75, so it does not fire today, but it would the moment the threshold is lowered (and the pack currently asks for 0.68 — see B). Treat "did not collide" as meaning "did not collide *above the threshold in force*", and re-run the measurement whenever either the threshold or the model changes, per pack and per language.

### D. The duplicate copy — outside this package

`STT/STT/Services/NLU/NLUEngine.swift` is a pre-package copy of the engine with the same bug, and it is still compiled into the app (`STT.xcodeproj/project.pbxproj:38`, `PBXFileSystemSynchronizedRootGroup` over `STT/`). The app's live view models use *that* copy — only `STTApp.swift`, `PackageVoiceView.swift` and `NLUOTAManager.swift` import `VoiceAIKit`.

**Fixing the package alone does not fix the app.** Either patch both or remove the duplicate from the build. See `VIK_DEFECT_AUDIT.md` §12.

---

## 10. Tests

None of today's 142 tests covers interruption. These are the ones to add — four of them fail against today's code, which is the point.

| # | test | asserts |
|---|---|---|
| 1 | `openSlotKeepsACommandShapedAnswer` | reminder → name prompt → "Need to go to walk" → `.prompt` for date_time, `filled["name"]` set. **Fails today.** |
| 2 | `openSlotKeepsAHearingAidChoreAsTheName` | same with "clean my hearing aids". **Fails today.** |
| 3 | `closedSlotStillInterruptsOnAValueItCannotAccept` | memory → "increase volume" (scripted 0.99 other intent) → `.interrupted(cancelledIntent: memory)` |
| 4 | `closedSlotFillsAGazetteerValueWithoutAskingTheClassifier` | memory → "custom two" (scripted 0.99 other intent) → fills, not interrupted. **Fails today.** |
| 5 | `wholeUtteranceDeclineCancelsAnOpenSlotFlow` | reminder → name prompt → "cancel" → `.fulfill` with `sys.confirm.cancelled`, `isCollecting == false`. **Fails today.** |
| 6 | `multiWordCancelPhraseMatchesAsPrefix` | "leave it for now" → cancels. **Blocked on §9C.1** — the pack's `negative` list has no multi-word cancel phrase to match, so this test cannot pass until `cancel_phrases` ships. Write it, mark it `XCTSkip` until then. |
| 7 | `aDeclineWordInsideALongerAnswerDoesNotCancel` | "no sugar in my coffee" → fills as the name |
| 8 | `dayOnlyAnswerParksTheDayAndDoesNotDoubleAdvanceIt` | "buy milk" → "tomorrow" → "9am" → ISO lands on **tomorrow**, not the day after. **The regression guard for trap A.** |
| 9 | `aFilledSlotDoesNotCallTheClassifier` | scripted classifier call counter unchanged across a gazetteer-resolved answer |

**Test-writing notes learned the hard way:**

- `ConfirmationAndSlotFlowTests.StubClassifier` returns the same label for every utterance and cannot express "this answer looks like another intent". A scripted stub (utterance → verdict) plus a call counter is needed.
- The package builds under `swiftLanguageModes: [.v6]`. Any struct the scripted stub takes across the actor boundary (a `Verdict` payload, say) needs an explicit `: Sendable`. Untested — the stub written during review was never compiled.
- Use `"9am"` (no space) for the bare-time step. `Fixtures/reference_expectations.json` proves that form resolves with `timeExplicit=true, dayExplicit=false`; `"5 pm"` is unverified.
- `"set a reminder"` is the right opening: it hits the Stage-0 keyword rule `\b(set|create|add|make)\b.{0,20}\breminder\b`, and the pack's carriers strip it to `""`, so `fillOpenTopics` does **not** pre-fill the name and the first prompt is the name prompt. Verified.
- `"change memory"` matches **no** keyword rule (the `Cmd.MemoryChange` rules require a trailing `for`, or `mode`, or `load/restore my usual config`), so the stub decides the intent. Verified.
- Derive intents through `PackTestSupport.intent(requiringSlots:in:)`; never hardcode labels. Derive the "other intent" for switch verdicts the same way.
- Existing tests should be unaffected: the decline/accept word tests run through the **confirmation** path (priority 1), which never reaches `handleSlotFilling`. Assessed by reading, not by running.

---

## 11. Rollout order

1. **A** — engine fill-first + cancel matching + tests. Small, self-contained, revertible.
2. **C.1** — `cancel_phrases` in the pack. Engine already reads it via the defaulted parameter.
3. **B** — wire `thresholds.interrupt`, separately.
4. **D** — resolve the duplicate engine in the app target.
5. **C.2** — `sys.cancel` trained intent, next model.
6. **C.3** — per-slot interrupt scope, if field data shows the extra turn matters.

---

## 12. Open questions and unverified assumptions

**Scope note.** Everything below is a gap in the *findings* in this document. None
of it describes a problem in the repository — `VoiceAIKit` is untouched and nothing
in §7 or §8 has been implemented. Risks that belong to *writing* that code are
noted inline where the code is (§7 step 3, §10's test notes), not here.

Close these before merging an implementation.

1. **Nothing here was compiled or run.** The device VM has no Swift toolchain (`swift: command not found`). All analysis is from reading source. `swift build && swift test` is step one.
2. **The classifier simulation is Python, not the CoreML head.** sklearn tokenisation and sublinear TF-IDF were reproduced per `PackTFIDFVectorizer.swift`'s own doc comment, using the pure-Swift fallback weights. `PackIntentClassifier.swift` states that ANE and CPU return *different* logits from the same model, so exact confidences may shift by a few points on device. The conclusions do not depend on precision — the gaps are 0.75 vs 0.99 — but any number used to pick a threshold or an allowlist must be re-measured on device.
3. **The Python engine's ordering was never checked** (§3). This determines whether the server side has the same bug.
4. **Only `pack-en-v1.0.38-ios` was examined.** The design keys off flags (`open`, `isDateTime`), not intent names, so it should carry to other languages — confirm.
5. **`Cmd.MemoryChange`'s gate is `never`** in this pack, so the memory traces here have no confirmation step. A pack that gates it `always`/`when_ambiguous` produces a different flow (confirm first, then slots).
6. **`"change memory to car"` was not run through `PackDateTimeParser`.** The §6 trace assumes it yields no date. If it accidentally parses something, the deferred interrupt would not fire either.
---

## 13. Related defects found while investigating

Not part of this work, recorded so they are not lost. Full detail in `VIK_DEFECT_AUDIT.md`.

- **`startLiveTranscription()` re-entrancy** → two concurrent sessions → the stale results loop corrupts `hasReceivedFinalResult` → no final delivered → **mic hangs open**. `TranscriptionCoordinator.swift:245` guards on `state.isActive`, which is false for `.requestingPermissions` and `.preparingAudio`.
- **`stop()` during a start is ignored** — the in-flight start continues and turns the mic on afterwards.
- **`AudioCaptureService` uses an unbounded `AsyncStream`** for mic buffers (`:57`), while `AppAudioInputProvider` correctly uses `.bufferingNewest(32)` with a comment explaining why. The correct policy is on the path nobody uses.
- **`TranscriptionCoordinator.results`** — unbounded stream, yielded to on every partial, **zero consumers**. A live leak.
- **`ConversationSpeaker.stop()`** is a no-op during `speak()`'s queue hop, so TTS plays after cancellation.
- **OTA zip-slip** — `PackValidator.extractAndValidate` extracts a host-supplied archive *before* any verification and never checks containment.
- **Unsanitized path components** — `language` (public API) and `version` (from the manifest) flow into `removeItem`/`moveItem`.
- **Dead code** — `IntentResult` (~135 lines) is never constructed; `transcribeFile` + `FileCaptureService` (~250 lines) are unreachable from the public API.
