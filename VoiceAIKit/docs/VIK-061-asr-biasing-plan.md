# VIK-061 — ASR biasing from the pack's keyword rules (iOS)

**Status:** proposed — **spike-gated**
**Owner:** VoiceAIKit / Speech
**Pack under test:** `pack-en-v1.0.54`
**Android counterpart:** `nlupack/NluBiasingDeriver.kt` (207 lines) + `speech/SpeechManager.kt:743`
**Companion:** [`things-to-pull-from-android.md`](./things-to-pull-from-android.md) · [`VIK-055-keyword-arbitration-plan.md`](./VIK-055-keyword-arbitration-plan.md)

---

## 0. Correction to the earlier recommendation — read this first

I previously recommended this as unconditional P1, on the assumption that iOS
would set `SFSpeechRecognitionRequest.contextualStrings`, the direct analogue of
Android's `RecognizerIntent.EXTRA_BIASING_STRINGS`.

**That assumption is wrong for this codebase.** `SpeechRecognitionService.swift`
does not use `SFSpeechRecognizer` at all. It is built on the iOS 26
`SpeechAnalyzer` + `SpeechTranscriber` API — `SpeechTranscriber(locale:preset:)`,
`SpeechAnalyzer(modules:)`, `analyzer.start(inputSequence:)` at line 457.

On that API the biasing surface reads as follows:

| Symbol | What Apple's docs say |
|---|---|
| `AnalysisContext.contextualStrings: [ContextualStringsTag: [String]]` | "Words or phrases, grouped by tag, that should be recognized even if they are not in the system vocabulary." iOS 26+. |
| `SpeechAnalyzer.setContext(_:)` / `.context` | "Sets contextual information to improve or inform the analysis." Available regardless of module. |
| `DictationTranscriber` | Has an explicit **"Improve accuracy"** section: build an `AnalysisContext`, add `contextualStrings`, set it on the analyzer. Also supports `SFSpeechLanguageModel` via `ContentHint.customizedLanguage(modelConfiguration:)` and algorithm hints such as `farField`. |
| **`SpeechTranscriber`** | **No such section, and no `ContentHint` type at all.** Its entire configuration surface is `Preset`, `TranscriptionOption`, `ReportingOption`, `ResultAttributeOption`. |

And an Apple developer-forums thread on `AnalysisContext` states directly that
contextual strings work with `DictationTranscriber` and that **`SpeechTranscriber`
does not currently take them into account.**

So the API call is legal — `setContext` is on the analyzer, not the module — but
whether it does anything for the module this app uses is **unverified and,
on the documentation, unlikely.**

**Consequence for priority.** VIK-061 is no longer an unconditional P1 ahead of
VIK-055. It becomes **spike-first**: §5 is a timeboxed measurement that decides
whether there is a change to make at all, and which of three routes it is. The
deriver itself (§6) is worth building regardless — it is pure string work,
API-independent, and every candidate route consumes its output.

**Do not treat any of the above as settled.** Apple's documentation is not the
device. §5 exists because the only acceptable evidence here is a measurement on
hardware.

---

## 1. Why bias at all

Biasing sits **upstream of every NLU item in the backlog.** If the recogniser
hears *"creed a reminder"*, the keyword rule misses, the model misses, and no
amount of arbitration correctness (VIK-055) recovers the turn. It is also the one
item that improves the *measurement* of everything downstream, by removing
transcription noise from a holdout delta.

The pack already contains the vocabulary worth biasing toward — the keyword rules
are, by construction, the phrases the product most wants recognised. Deriving the
hint list from them costs nothing at authoring time and is language-agnostic: a
future `pack-fr` gets French biasing with no code change.

---

## 2. What Android does

`NluBiasingDeriver.phrasesFrom(patterns)` turns each keyword regex into the
literal phrases it can produce. It reads a **deliberately small subset of regex**
and **abandons a branch the moment it leaves that subset** — its own comment:
*"Skips any regex shape it cannot read exactly, because a wrong hint actively
hurts."*

Grammar it understands:

| Construct | Handling |
|---|---|
| top-level `\|` | split into branches; `\|` inside a group does not split |
| `\b`, `^`, `$` | consumed, contribute no text |
| `\s`, `\s+`, `\s*` | one space |
| `\ ` (escaped space) | a space |
| `\'` and other escaped non-alphanumerics | the literal character |
| any other `\x` | **bail out** — return no phrases for this branch |
| `.{0,N}` | one space (the gap between two words) |
| bare `.`, `.*` | **bail out** |
| `(a\|b\|c)` and `(a\|b\|c)?` | a slot; `?` adds the empty option |
| nested `(` inside a group | **bail out** |
| a group option containing any metacharacter | **bail out** |
| group followed by `*` or `+` | **bail out** |
| `x?` (single preceding char optional) | slot of `[x, ""]` |
| `[`, `]`, `{`, `}`, `*`, `+` anywhere else | **bail out** |

Then a cross product over the slots, with bounds:

| Bound | Value | Purpose |
|---|---|---|
| `MAX_COMBINATIONS` | 64 | a branch whose cross product exceeds this is skipped entirely |
| `MAX_PER_PATTERN` | 12 | one wide alternation cannot dominate the list |
| `MAX_TOTAL` | 120 | cap on the whole list handed to the recogniser |
| `MIN_PHRASE_LENGTH` | 4 | biasing "up" or "it" does more harm than good |

Post-filters: whitespace collapsed, trimmed, deduplicated (insertion-ordered),
and every phrase must be letters/digits/space/apostrophe/hyphen only.

One subtlety worth carrying over verbatim: group options are **not trimmed**,
because in `(let me )?` the trailing space is load-bearing — trimming turns
`don'?t (let me )?forget` into `don't let meforget`.

Delivery is soft-failing: `OfflineNluServiceImpl.biasingPhrases()` wraps the
derivation in `runCatching` and returns `emptyList()`, because an unreadable pack
must never fail the turn.

---

## 3. What iOS's speech stack actually is

```
VoiceIntentSession
  └─ TranscriptionCoordinator(locale:)
       └─ SpeechRecognitionService          (1023 lines)
            ├─ prewarm() → performPrewarm() → builds a SpeechTranscriber + SpeechAnalyzer ahead of time
            └─ startTranscribing(...)
                 ├─ resolveTranscriberLocale(currentLocale)
                 ├─ reuse prewarmed pair when the locale and preset match, else build fresh
                 ├─ SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)
                 └─ analyzer.start(inputSequence:)        ← line 457
```

Two facts that shape the wiring:

- **The pack and the recogniser already meet.** `VoiceIntentSession.performFirstStart`
  builds the engine *first*, then configures the recogniser, and already guards
  the locale against the pack's language — "the session running the pack's
  language through a recogniser listening in a different one — a Danish pack
  transcribed as English, with no error, no event". That guard is the natural
  place to also hand over the biasing list.
- **Prewarm is a hazard.** A prewarmed analyzer is built before the pack's
  phrases are known and is later adopted by `startTranscribing`. Any context must
  therefore be applied **to whichever analyzer is actually adopted**, immediately
  before `analyzer.start`, not at construction — otherwise the prewarm path
  silently ships an unbiased analyzer and the cold path a biased one, which is
  the worst possible A/B.

---

## 4. Candidate routes

The spike picks one. They are not equivalent in cost or in blast radius.

### Route A — `AnalysisContext` on the existing `SpeechTranscriber`

```swift
let context = AnalysisContext()
context.contextualStrings = [AnalysisContext.ContextualStringsTag("commands"): phrases]
try await analyzer.setContext(context)     // before analyzer.start(inputSequence:)
```

- **Cost:** ~10 lines on top of the deriver.
- **Blast radius:** none — no change to the transcriber, preset, model, or locale.
- **Risk:** on Apple's documentation this is likely a **no-op** for
  `SpeechTranscriber`. Harmless, but worthless.
- **Verdict rule:** ship it only if the spike shows a measurable WER/keyword-hit
  improvement. A no-op that "looks right" is worse than nothing — it creates the
  belief that biasing is handled.

### Route B — switch to `DictationTranscriber`

`DictationTranscriber` documents the biasing path and additionally supports
`SFSpeechLanguageModel` via `ContentHint.customizedLanguage(modelConfiguration:)`,
plus algorithm hints such as `farField` — the latter is independently interesting
for a hearing-aid microphone.

- **Cost:** high. Different module, different `Result` type, different
  `supportedLocales` / `installedLocales`, different asset-install path, and the
  preset/option enums are module-specific. `SpeechRecognitionService`'s prewarm,
  locale resolution, result iteration and finalisation all assume
  `SpeechTranscriber`.
- **Blast radius:** the entire transcription layer. `DictationTranscriber` uses
  "the same models as system dictation… or as `SFSpeechRecognizer` when configured
  for on-device operation" — a **different engine**, so baseline transcription
  quality changes for every utterance, biased or not.
- **Verdict rule:** only if Route A is a no-op **and** the spike shows biasing is
  worth a transcription-engine change. That is a product decision, not an
  engineering one, and it needs a full WER comparison of the two engines on the
  same audio — not just a keyword-hit-rate comparison.

### Route C — post-ASR lexical repair inside VoiceAIKit

No Apple API dependency at all: take the same derived phrase list and, on the
final transcript, repair near-misses before the NLU sees them
("creed a reminder" → "create a reminder").

- **Cost:** medium. Needs a conservative matcher and a clear rule for when NOT to
  fire.
- **Blast radius:** contained inside the kit, but it **rewrites the user's words**,
  which is a real hazard — `PackSlotResolver` already refuses fuzzy matching on a
  speculative sweep for exactly this reason, and `NLUEngine`'s VIK-017 note records
  what happened when an open slot's gazetteer rewrote "drink water" into
  "Drink Water".
- **Constraints if chosen:** repair only for the **keyword-match probe**, never
  the transcript handed to the model, the slot resolver, or the UI. That keeps the
  blast radius at "a keyword rule fires that otherwise would not" and leaves the
  model's own reading of the raw words untouched — and it composes correctly with
  VIK-055, where a keyword match is a vote rather than a verdict.
- Android has nothing like this. It is listed because it is the only route whose
  feasibility does not depend on an Apple answer.

---

## 5. Phase 0 — the spike (gates everything below)

**Timebox: 2 days. Output: a decision, not a branch.**

### 5.1 Corpus

20–30 recorded utterances, real audio, on the target hardware and microphone
path (hearing aid **and** phone mic — Android's own tuning notes a ~140 ms vs
~20 ms chunk cadence between the two, so they are not interchangeable). Weighted
toward:

- utterances whose keyword rule is the only thing that would route them
- known-misheard phrases from field logs, if any exist
- entity-bearing utterances ("send a message to <name>") where the OOV token is
  the point

Record once, replay against every configuration. Live re-speaking is not a
controlled comparison.

### 5.2 Configurations

| # | Config | Question it answers |
|---|---|---|
| 1 | `SpeechTranscriber`, no context | baseline |
| 2 | `SpeechTranscriber` + `AnalysisContext.contextualStrings` | **Is Route A a no-op?** |
| 3 | `DictationTranscriber`, no context | what does the other engine cost/gain on its own? |
| 4 | `DictationTranscriber` + `contextualStrings` | what does biasing buy where it is documented? |

### 5.3 Metrics

Per configuration: word error rate; **keyword-rule hit rate** (share of utterances
where the intended rule fires on the transcript — this is the metric that actually
matters, and it is computable offline from the pack); and per-utterance
transcripts committed to the PR so a disagreement is inspectable rather than
argued.

### 5.4 Decision rule

- **(2) beats (1) materially** → **Route A.** Small PR, ship it.
- **(2) ≈ (1) and (4) beats (3) materially** → escalate **Route B** as a product
  decision with the (1)-vs-(3) engine comparison attached. Do not start it on
  engineering judgment alone.
- **Neither** → **Route C**, or close VIK-061 as *not available on this API* and
  record the finding. Closing it with evidence is a perfectly good outcome; it
  stops the next person re-deriving the same wrong assumption I did.

### 5.5 What the spike must NOT do

Do not land the deriver behind the spike. §6 is separable and independently
testable — building it first means the spike measures the real phrase list rather
than a hand-written approximation, and it survives every decision-rule branch
except an outright close.

---

## 6. The deriver port (unconditional work)

`Pack/Loader/PackBiasingDeriver.swift` — a direct port of `NluBiasingDeriver`.
Pure string work, no Speech dependency, no Foundation regex engine involved: it
*parses* the pattern, it does not execute it. That is what makes it portable and
what makes an exact parity test possible.

### 6.1 Shape

```swift
enum PackBiasingDeriver {
    /// Literal phrases derived from `patterns`, in pattern order, deduplicated
    /// and bounded. A pattern whose shape this does not read exactly contributes
    /// nothing — a wrong hint is worse than no hint.
    static func phrases(from patterns: [String]) -> [String]
}
```

Bounds as **named constants with the Android values**, not literals:
`maxPerPattern = 12`, `maxTotal = 120`, `maxCombinations = 64`,
`minPhraseLength = 4`. If iOS later needs different bounds (a different API cap),
change them **with a measurement and a comment**, never silently — a divergence in
bounds is a divergence in behaviour that no test would otherwise catch.

Call site mirrors Android's soft failure:

```swift
// An unreadable pack must never fail the turn. Empty means "no biasing".
let phrases = (try? PackBiasingDeriver.phrases(from: pack.keywordRules.map(\.pattern))) ?? []
```

### 6.2 Character-class parity — the one real porting hazard

Kotlin's `Char.isLetterOrDigit()` and Swift's `Character.isLetter || .isNumber`
are **not the same predicate** across the whole Unicode range, and
`PackTFIDFVectorizer.tokenize` already carries a comment about exactly this class
of mismatch (it avoids `CharacterSet.alphanumerics` for the same reason).

This matters in three places in the deriver: `isPlainLiteral`, `isUsablePhrase`,
and the "escaped non-alphanumeric" branch. For `pack-en` the inputs are ASCII and
the two agree — but `pack-fr`'s reminder patterns already carry `[eé]` classes
(`cr[eé]er?\s+un\s+rappel`), which the deriver bails out on, and a future pack may
carry accented literals that do not bail.

**Write the predicate explicitly** (letters, digits, space, apostrophe, hyphen)
rather than delegating to a platform helper, and assert it in a test over a
non-ASCII fixture.

### 6.3 Parity fixture

Follow the `TopicDerivationParityTests` precedent, whose header states the reason
plainly: *"Two suites written independently agree until someone changes one of
them… 8 of 20 utterances diverged without anything failing."*

- Emit `Fixtures/biasing_expectations.json` from the **Kotlin** deriver over
  `pack-en-v1.0.54`'s 37 patterns — a tiny Kotlin/JVM main, or a throwaway test
  that prints the list. Commit it.
- `PackBiasingDeriverTests` asserts the Swift output equals it, **element for
  element and in order** — order is part of the contract, because `MAX_TOTAL`
  truncates and a reordering changes which phrases survive the cap.
- Regenerate whenever `keywords/*.json` changes. Add a test that fails if the
  fixture's recorded pack version does not match the vendored pack's — otherwise a
  pack bump silently invalidates the fixture, which is the same failure mode the
  fixture exists to prevent.

### 6.4 Expected output on this pack

Unknown until it runs. Worth recording in the PR: how many of the 37 patterns
produce phrases, how many bail out, and the final list length against the 120 cap.
The three `reminders.add` rules are a good sanity check — the first
(`\b(set|create|add|make)\b.{0,20}\breminder\b`) should yield four phrases of the
shape "set reminder", "create reminder", …; the third (the French alternation)
should bail out on `[eé]`.

---

## 7. Wiring (shape only — the route decides the detail)

1. `PackEngineFactory.makeEngine` already holds the `ResolvedPack`. Derive the
   phrase list there, or expose it on `ResolvedPack` as a lazy property — it is
   pack-derived, computed once, and belongs with the pack rather than with the
   session.
2. `VoiceIntentSession.performFirstStart` already resolves the locale against the
   pack's language. Hand the list to the coordinator at that same point, so the
   phrases and the locale are set together and cannot disagree.
3. `SpeechRecognitionService` stores it and applies it **immediately before
   `analyzer.start(inputSequence:)` (line 457)**, on whichever analyzer was
   adopted — prewarmed or fresh. See §3; applying it at construction misses the
   prewarm path.
4. Log the count, never the phrases, mirroring Android
   (`"biasing phrases set count=%d"`). The phrases are pack content rather than
   user speech, so this is not a privacy constraint — it is a log-volume one, and
   the count is what a field report actually needs.

---

## 8. Tests

| Test | Asserts |
|---|---|
| `PackBiasingDeriverTests` — fixture parity | Swift output == Kotlin output, in order (§6.3) |
| — bail-out cases | a pattern with a nested group, a bare `.`, a `*`-quantified group, or an unknown `\x` yields **no** phrases |
| — bounds | `maxCombinations` skips a wide branch entirely; `maxPerPattern` and `maxTotal` truncate; a phrase shorter than `minPhraseLength` is dropped |
| — the `(let me )?` case | group options are not trimmed; no `"let meforget"` in the output |
| — non-ASCII predicate | §6.2; the French alternation bails out rather than emitting mojibake |
| — determinism | two calls on the same input give an identical, identically-ordered list |
| `PackLoadingTests` addition | the vendored pack produces a non-empty list, and its length is `<= maxTotal` |
| Route-specific integration | only written once the spike picks a route — a test against an unverified mechanism is a test of nothing |

---

## 9. Validation gates

1. `swift test` green.
2. Fixture parity test passing against a **freshly regenerated** fixture, not the
   committed one, at least once in review.
3. The §5 spike numbers attached to the PR — baseline vs chosen route, on both
   microphone paths.
4. **No regression in keyword-rule hit rate.** Biasing can hurt: an aggressive
   hint list pulls unrelated speech toward pack phrases. The spike corpus must
   include utterances that should *not* match any rule (the equivalent of
   `"what is the weather in bangalore tomorrow"` in the parity fixture), and their
   hit rate must stay at zero.
5. Derivation cost measured once at engine build, not per turn. Assert it is
   computed once — a 37-pattern cross product on every utterance would be a real
   regression.

---

## 10. Rollback

The kill switch is the empty list, and it needs no flag: `phrases == []` is
already the documented "no biasing" state and the soft-failure result. A pack
whose keyword rules all bail out produces exactly that, and nothing downstream
changes behaviour.

If Route B is ever taken, that is **not** covered by this rollback — a transcriber
swap needs its own staged rollout and its own revert path, which is part of why it
is gated on a product decision rather than this plan.

---

## 11. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `SpeechTranscriber` ignores `contextualStrings` | **High** (per Apple's docs) | Route A is a no-op | §5 spike is the whole point; §5.4 says to close the ticket with evidence rather than ship a placebo |
| Shipping a no-op that *looks* like biasing | Medium | Worse than nothing — creates false confidence | Decision rule requires a measured improvement before shipping |
| Biasing pulls unrelated speech toward pack phrases | Medium | False keyword matches | §9.4 negative corpus; `minPhraseLength` and the caps exist for this |
| Kotlin/Swift character-class drift | Medium | Silent divergence on a non-ASCII pack | §6.2 explicit predicate + non-ASCII fixture case |
| Prewarmed analyzer ships unbiased | Medium | Inconsistent behaviour between first and later turns | §7.3 — apply before `start`, not at construction |
| Fixture goes stale after a pack bump | Medium | Parity test passes while describing an old pack | §6.3 pack-version assertion |
| Route B scope explosion | Low (gated) | Transcription layer rewrite | Requires a product decision with a full WER comparison |

---

## 12. Sequencing

```
         ┌─ §6 deriver + parity fixture  ── independently valuable, land first
         │
§5 spike ─┼─ (2) > (1) ──────────────────→ Route A. Small PR. Done.
         │
         ├─ (2) ≈ (1), (4) > (3) ────────→ escalate Route B as a product decision
         │                                  (attach the (1)-vs-(3) engine comparison)
         │
         └─ neither ─────────────────────→ Route C, or close with the finding recorded
```

**Revised position relative to VIK-055.** My earlier advice was to land VIK-061
before VIK-055. That was based on the wrong API. The corrected sequencing:

| | Work | Why here |
|---|---|---|
| now, parallel | §6 deriver + fixture · §5 spike | Neither touches the NLU; the spike answers a question nobody currently has an answer to |
| now | **VIK-055** — the planned arbitration fix | It is the reported defect, it is fully specified, and it is no longer blocked on this |
| after the spike | Route A / B / C, or close | Evidence decides |

VIK-055 is the one to start. This plan runs beside it, not in front of it.

---

## Appendix — source anchors

| What | Where |
|---|---|
| Android deriver | `nlupack/NluBiasingDeriver.kt` |
| Android delivery + soft failure | `speech/SpeechManager.kt:218-219, 741-743`; `OfflineNluServiceImpl.kt:33-41` |
| iOS transcriber construction | `Core/Recognition/SpeechRecognitionService.swift:293-300` |
| iOS prewarm path | `SpeechRecognitionService.swift:138-189, 262-286` |
| iOS analyzer start (context goes before this) | `SpeechRecognitionService.swift:457` |
| iOS pack↔locale guard (hand-off point) | `Facade/VoiceIntentSession.swift:~292` |
| Character-class precedent | `Pack/Loader/PackTFIDFVectorizer.swift::tokenize` |
| Parity-fixture precedent | `Tests/VoiceAIKitTests/TopicDerivationParityTests.swift` (header) |
| Why rewriting user words is hazardous | `NLUEngine.swift` VIK-017 note; `PackSlotResolver` `isDirectAnswer` |

### Apple documentation consulted

- [`AnalysisContext`](https://developer.apple.com/documentation/speech/analysiscontext) — `contextualStrings`, `ContextualStringsTag`, iOS 26+
- [`SpeechAnalyzer`](https://developer.apple.com/documentation/speech/speechanalyzer) — `setContext(_:)`, `context`, `prepareToAnalyze(in:)`
- [`SpeechTranscriber`](https://developer.apple.com/documentation/speech/speechtranscriber) — no contextual-strings or content-hint surface
- [`DictationTranscriber`](https://developer.apple.com/documentation/speech/dictationtranscriber) — "Improve accuracy": `contextualStrings`, `SFSpeechLanguageModel`, `ContentHint`
- [Apple Developer Forums — "SpeechAnalyzer > AnalysisContext lack of documentation"](https://developer.apple.com/forums/thread/811083) — states `SpeechTranscriber` does not take contextual strings into account

> These are documentation and a forum answer, not the SDK and not the device.
> §5 exists because only a measurement on hardware settles it.
