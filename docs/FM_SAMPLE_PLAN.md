# Foundation Models Intent Classification — Implementation Plan (iOS Sample)

**Status:** Plan only — no implementation yet
**Related:** [ON_DEVICE_NLU_OVERVIEW.md](./ON_DEVICE_NLU_OVERVIEW.md) · [ON_DEVICE_NLU_TECHNICAL_DETAILS.md](./ON_DEVICE_NLU_TECHNICAL_DETAILS.md)

---

## 1. Goal and non-goals

**Goal:** add a fourth option — **"Foundation Model"** — to the app's first screen, which runs the complete voice → intent → action flow using Apple's Foundation Models framework as the classifier, covering every capability the current system has (all 59 intents, out-of-scope rejection, entity extraction, slot filling, confirmation, multi-turn context), for side-by-side evaluation against the existing cascade.

**Non-goals:** replacing any existing tier, modifying any existing classifier/engine/UI code, shipping this to production users. This is an evaluation sample.

## 2. Ground rules

1. **Zero modification of existing logic.** The only permitted edits to existing files are two *purely additive* insertions (§6). Everything else is new files.
2. **All FM code physically isolated** in one new folder: `STT/Services/FoundationModelNLU/` (app target, not VoiceIntentKit — keeps the package clean and the sample disposable). Every new type prefixed `FM` so ownership is unambiguous.
3. **Compile-safety on older SDKs:** all FM files wrapped in `#if canImport(FoundationModels)` + `@available(iOS 26, *)`; the app must still build and run exactly as today if the framework is absent.

## 3. Architecture — the one big decision

**Reuse the existing conversation stack; replace only the classifier.**

The existing `NLUEngine` (slot filling, confirmation gates, context lifespans, priority routing) consumes any actor conforming to `IntentClassifying` — one method, `classifyAsync(_ text:) async -> ClassificationResult`. So:

```
Speech (existing) → FMIntentClassifierService (NEW, conforms to IntentClassifying)
                  → NLUEngine (existing, untouched)
                  → EntityExtractor (existing, untouched)
                  → Business logic / TTS (existing, untouched)
```

This single decision is what guarantees "cover all cases of the current system": multi-turn dialogue, slot prompts, yes/no confirmation, entity memory, session expiry, and routing priority are *inherited*, not re-implemented — because they were never in the classifier to begin with.

## 4. New components (all in `STT/Services/FoundationModelNLU/`)

| File | Responsibility |
|---|---|
| `FMAvailability.swift` | Wraps `SystemLanguageModel.default.availability`. Exposes: available / device-not-eligible / Apple-Intelligence-off / model-downloading, with a user-facing message for each. Checked before the option is enabled. |
| `FMIntentSchema.swift` | The `@Generable` enum of all 59 intents **plus an explicit `outOfScope` case** (mirrors the learned OOS class in the current system). Includes a `@Guide` description per case, sourced from the intent catalog. |
| `FMSchemaParityTests.swift` (test target) | Unit test asserting the enum's raw values exactly match `intent_labels.json` / the NLU schema — count and spelling. This is the drift guard: if someone adds intent #60 to the real system, this test fails until the FM enum follows. |
| `FMClassificationOutput.swift` | The `@Generable` response struct: intent case + **verbatim** slot phrases (datetime phrase, entity mentions, message body as literally spoken) + optional self-rated confidence (see §5). |
| `FMPromptBuilder.swift` | Builds the session instructions from the intent catalog: intent names, one-line descriptions, 2–3 few-shot examples for the historically confusable pairs (e.g. `Help_HeartRate` vs `Help_HeartRateRecovery`, `Cmd.VolumeMute` vs `Cmd.VolumeDecrease`). Token budget explicitly tracked — the catalog must fit comfortably inside the 4,096-token context with room for the utterance and output. |
| `FMIntentClassifierService.swift` | The actor conforming to `IntentClassifying`. Owns the `LanguageModelSession` lifecycle: prewarm on entry, `temperature: 0` (greedy — minimizes variance), per-call timeout, error mapping (session busy / rate-limited / model unloaded → the same "unknown" result shape the existing classifiers return, so `NLUEngine` behaves identically on failure). Maps `FMClassificationOutput` → the existing `ClassificationResult` type. |
| `FMMetrics.swift` | Per-call log record: utterance, chosen intent, latency, prompt token estimate, OS version, device model. Feeds the benchmark (§8). |
| `FMVoiceView.swift` + `FMVoiceViewModel.swift` | The screen for this mode. Clone the structure of `PackageVoiceView` (the existing third option — already the template for "self-contained sheet driving a session"), swapping in the FM classifier. Shows a small "FM" badge + per-turn latency so evaluators always know which engine answered. |

## 5. Covering every current-system case — the explicit matrix

| Current capability | How FM mode covers it |
|---|---|
| 59-intent classification | `@Generable` enum — constrained decoding makes an invalid label structurally impossible |
| Out-of-scope rejection | Explicit `outOfScope` enum case, described in instructions as "anything not matching the operations above" — same *design* as the learned OOS class |
| Negation ("I don't want to translate") | Handled by the model's language understanding rather than the 30-char lookback rule; **must be in the test set** (§8) since it's a known strength of the current system |
| Entity extraction (datetime, enums, fuzzy values) | **Hybrid — the critical design point.** FM extracts slot phrases *verbatim* ("tomorrow morning at 9"); resolution to concrete values is delegated to the **existing** `EntityExtractor` / datetime grammar. FM never resolves dates itself. This preserves the carefully-reviewed deterministic resolution and means a 3B model can't silently botch clock-idiom conventions. |
| Slot filling (prompt for missing params) | Inherited — `NLUEngine`, untouched |
| Yes/no confirmation before consequential actions | Inherited — `NLUEngine`, untouched |
| Context lifespans, entity memory, session expiry | Inherited — `NLUContext`, untouched |
| Priority routing (confirmation > slot-fill > fresh) | Inherited — `NLUEngine`, untouched |
| Confidence gating (0.70 / 0.55 thresholds) | **Cannot be replicated — no logprobs exposed.** Decision: guided output is treated as accepted; the optional self-rated confidence is *display-only, explicitly labeled uncalibrated*, never used for gating. This is a documented, deliberate gap — it's the headline finding the benchmark exists to characterize, not a bug in the plan. |
| Cloud fallback for out-of-scope | In FM mode, `outOfScope` is terminal (spoken "I can't help with that") — no network call. Optional phase 2: route it to the existing genai fallback for parity with the cascade. |
| Unknown/low-confidence logging (`unknown_data.csv` equivalent) | `FMMetrics` logs every `outOfScope` and every turn, locally |
| Multilingual (fr/de/da) | **Explicitly out of scope for the sample** — Apple Intelligence doesn't cover Danish at all. FM option is English-only, stated on-screen. This is a finding, not an omission. |

## 6. The only two touches to existing files (both additive)

1. **`STTTestView.swift`:** add `case foundationModel` to `PipelineChoice` + its title ("Foundation Model") + one `.sheet` presentation mirroring the existing `showPackageSession` pattern. The option renders disabled with the reason string from `FMAvailability` on ineligible devices (don't hide it — an evaluator with an old phone should see *why*).
2. **Xcode project:** new files added to the app target; link `FoundationModels.framework` as weak/optional.

Nothing else. No existing type, method, or resource is edited.

## 7. Session lifecycle details

- **Prewarm** the session when the FM screen opens, not on first utterance — avoids a cold-start penalty polluting the first latency measurement.
- **One session per conversation, reset on session expiry** — matches the existing conversation-session semantics, and bounds context-window growth. If the transcript approaches the context limit mid-conversation, reset the session and re-inject only the instructions (conversation state lives in `NLUContext` anyway, so nothing user-visible is lost — a direct benefit of reusing the existing conversation manager).
- **Rate limiting:** serialize calls through the actor; if the framework reports the model busy, queue one turn and surface "thinking…" rather than erroring.
- **TTS overlap guard:** reuse the existing `isSpeaking` suppression pattern so FM isn't classifying its own TTS output.

## 8. Benchmark (the actual point of the exercise)

A debug-only "Run Benchmark" button on the FM screen:

- Feeds the existing **341-utterance / 59-intent holdout set** (bundle a copy of `semantic_holdout_2.csv` into the app as a test resource) through `FMIntentClassifierService` on-device.
- Produces a shareable CSV/JSON report: overall accuracy, per-intent accuracy, macro-F1, latency p50/p95, OOS precision/recall, OS + device + date (so results are attributable when Apple revs the model).
- **Success criteria, decided now, before any numbers exist:** FM earns a production conversation (for the fallback/Tier-3 slot only) if it reaches **≥ 89.4% overall** (parity with the cascade) *or* **≥ 95% on OOS rejection** (the fallback slot's actual job). Below both: the sample is archived with the report, and the question is closed with data.
- Additionally run the **negation and confusable-pair suites** as named subsets so weaknesses are localized, not averaged away.

## 9. Phases

| Phase | Deliverable | Effort |
|---|---|---|
| 0 | Folder scaffold, availability gate, fourth option visible (disabled state working on ineligible hardware) | 0.5 day |
| 1 | Text-input-only classification: type a phrase → FM intent + latency (no voice). Schema parity test green | 1 day |
| 2 | Full voice pipeline: speech → FM classify → existing NLUEngine → slot filling/confirmation → TTS | 1–1.5 days |
| 3 | Benchmark harness + report export; run on at least two eligible devices | 1 day |
| 4 | Findings write-up (one page, numbers vs. 89.4% baseline) → decision on the fallback/Tier-3 slot | 0.5 day |

**Total: ~4–5 days**, each of phases 1–3 ending in something demoable.

## 10. Risks & mitigations

| Risk | Mitigation |
|---|---|
| 59-case enum + descriptions blows the context budget | `FMPromptBuilder` asserts token estimate at startup; trim descriptions before trimming few-shots |
| Apple revs the OS model and results shift | Every report stamped with OS build; re-run benchmark on each iOS beta — that is the *point* of having the harness |
| Fine-grained Help_* intents confuse the 3B model | Confusable-pair few-shots; per-intent reporting will localize it |
| Evaluators test on ineligible devices | Disabled-with-reason UI state, checked in Phase 0 |
| Sample code leaks into production paths | `FM` prefix + single folder + no existing-file edits beyond the two named insertions; trivially deletable |
