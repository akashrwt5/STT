# Production Decision Report — CoreML Cascade vs. Apple Foundation Models

**Author:** Principal iOS Engineering review
**Scope:** Which intent-classification approach ships in production, and a complete
map of the conditions under which the Foundation Models path can and cannot run.
**Inputs:** the shipped 3-tier cascade (`IntentClassifierService` + training repo),
the FM evaluation sample (`STT/STT/Services/FoundationModelNLU/`, branch
`claude/fm-intent-sample`), field logs from the first on-device FM runs, and the
Foundation Models framework contract as of this writing.
**Related:** [FM_SAMPLE_PLAN.md](./FM_SAMPLE_PLAN.md) ·
[ON_DEVICE_NLU_OVERVIEW.md](./ON_DEVICE_NLU_OVERVIEW.md) ·
[ON_DEVICE_NLU_TECHNICAL_DETAILS.md](./ON_DEVICE_NLU_TECHNICAL_DETAILS.md)

---

## 1. Recommendation

**Ship the CoreML cascade as the production classifier. Do not make any core
feature depend on Foundation Models.** Adopt FM only in an *opportunistic,
additive* role — as the out-of-scope fallback responder on devices where it is
available — and only after the holdout benchmark clears the pre-agreed bars
(≥ 89.4% overall or ≥ 95% OOS rejection; see FM_SAMPLE_PLAN §8).

This is not a close call, and the reason is structural rather than a quality
judgment on Apple's model: **the cascade runs for 100% of our users under 100%
of conditions; the FM path runs for a minority of devices under conditions we
do not control — including a user toggle that can revoke it at any moment.**
A hearing-aid companion app cannot ship a primary control path that a Settings
switch can silently turn off.

---

## 2. Head-to-head comparison

| | CoreML cascade (production) | Foundation Models sample |
|---|---|---|
| Device coverage | Every device the app supports | Apple Intelligence-class hardware only (see §4.1) |
| Preconditions | None — models ship in the app bundle | Apple Intelligence enabled + model assets present + supported region/language |
| Can capability disappear at runtime? | No | **Yes** — user toggle, MDM policy, model re-download, OS update |
| Measured accuracy | **89.4%** on the 341-utterance / 59-intent holdout | Not yet measured (benchmark harness ready; run pending) |
| Confidence signal | Calibrated (temperature-scaled); gates every action | **None** — no logprobs; self-rating observed pinned at ≈1.0 in field logs |
| Latency per classification | ~2–10 ms (S1+S2), +8 ms if S3 fires | **~800–950 ms** (post stateless-session fix; 791–2847 ms before it) |
| Model versioning | Ours — checksummed in `manifest.json`, pinned per release | **Apple's** — updates with the OS, no pinning, no changelog we control |
| Behavior stability | Deterministic; same input → same output | Greedy sampling is deterministic *per prompt*, but the model itself changes under us with OS updates |
| Fixing a vocabulary gap | New training rows → retrain → re-export → redeploy (days) | One prompt line, effective next launch (minutes) — demonstrated with the "environment" synonym |
| Memory (resident) | ~13 MB (S1+S2) / ~100 MB with S3 loaded | ≈0 in-process (OS hosts the model) |
| Multilingual | en/fr/de/da trained and calibrated | Sample is English-prompted only. Apple Intelligence covers all four app languages as of iOS 26.1 (Danish added in the eight-language expansion), so FM multilingual is *possible* — but would need localized prompts/catalogs and per-language benchmarks |
| Safety layer | None needed — closed-label output | Framework guardrails can *refuse* prompts; a refusal is an error path we must absorb (relevant: hearing/health-adjacent phrasing) |
| Slot/entity extraction | Deterministic grammar incl. reviewed multilingual clock idioms | Not used — sample delegates to the same existing extractor (correct design; keeps this a classifier-only swap) |

**Field-run evidence (from the first device sessions):** the sample surfaced
three issue classes in a single short session — session-history contamination
(identical utterance classifying differently across turns; fixed by stateless
per-turn sessions), narration/fragment misclassification ("I sat at a busy
cafe" → `Cmd.ActivityStep`; mitigated by prompt rules), and vocabulary gaps
("change environment"; fixed by a catalog line). All were fixable, and fix
cost was impressively low — but each was discovered *by a human noticing*,
which is exactly what the missing confidence signal means in practice: the
model reported ≈1.0 self-confidence on every one of those errors.

---

## 3. Why the cascade wins for production — the four disqualifiers

These are the reasons FM cannot be the *primary* classifier for this product,
independent of how well it benchmarks:

1. **Coverage.** The classifier is the core interaction of the app. A primary
   path that excludes every non-Pro iPhone before the 15 Pro (and every user
   who leaves Apple Intelligence off) inverts the product's reliability story.
   The cascade's job is to work on the phone the user already owns; it does.
2. **Revocability.** Apple Intelligence is a user-visible switch, an MDM
   policy surface, and a regional rollout. A capability that can be revoked
   between turns cannot gate a medical-adjacent device's control path. The
   cascade cannot be revoked.
3. **No confidence signal.** Stage 4 (confidence gating) is the safety
   architecture of this system — it is what keeps a wrong guess from becoming
   a wrong action. FM provides nothing to gate on, and its self-rating is
   demonstrably uninformative (≈1.0 on every observed error). The engine's
   slot-interruption probe (≥ 0.75 bar) is similarly blind against an
   always-confident source — bounded today only because just 3 intents carry
   slot configs.
4. **Version control.** Every production model we ship is checksummed and
   holdout-gated per release. The OS model changes on Apple's cadence with no
   pin and no notice; our only defense is re-running the benchmark on every
   OS update — a monitoring burden, acceptable for an auxiliary role,
   unacceptable for the primary path.

**Where FM genuinely earns a seat:** the out-of-scope fallback slot — the
turns where the cascade has already said "I don't know." There, latency
tolerance is high, there is no calibrated confidence to lose (the cascade is
at its floor by definition), a guardrail refusal degrades to the same
"can't help" we show today, and the OS-hosted model costs us no memory. On
eligible devices this converts the current dead-end fallback into an actual
on-device answer; on ineligible devices, behavior is unchanged. That is an
additive improvement with no downside path — *pending benchmark numbers*.

---

## 4. Foundation Models availability — the complete conditions map

This is the section that answers "it supports only some devices, and what if
Apple Intelligence is not enabled." The framework reports availability via
`SystemLanguageModel.default.availability`; our wrapper (`FMAvailability`)
maps every state. Verified behaviors and their production implications:

### 4.1 Hardware eligibility — `.deviceNotEligible`

The on-device foundation model requires Apple Intelligence-class silicon:

| Device family | Eligible? |
|---|---|
| iPhone 15 Pro / 15 Pro Max (A17 Pro) and all iPhone 16/17-class devices | ✅ |
| iPhone 15 / 15 Plus (A16) — despite the "15" name | ❌ never |
| iPhone 14 family and older | ❌ never |
| iPad / Mac with M1 or later | ✅ |
| Older iPads (A-series before A17 Pro) | ❌ never |

Two implications specific to this product:

- **"iPhone 15" is a trap in fleet estimates.** The base iPhone 15/15 Plus
  are *not* eligible. Any coverage estimate keyed on "iPhone 15 or newer"
  overstates reality.
- **Our demographic skews toward older, longer-held devices.** Hearing-aid
  users replace phones slowly. Coverage will grow year over year as the
  fleet turns over — which is an argument for building the FM fallback
  *behind a gate* now and letting adoption grow into it, not for waiting.
- **Action item (product analytics):** pull the actual device-model
  distribution of our installed base and attach the real eligible-share
  number to this report. Every downstream decision improves with that one
  number.

### 4.2 Apple Intelligence disabled — `.appleIntelligenceNotEnabled`

Eligible hardware does not mean available capability:

- Apple Intelligence is an **opt-in Settings toggle**. Users can decline it
  at setup or disable it later at any time.
- **MDM / corporate policy** can force it off on managed devices.
- **Regional availability** is staged (EU and China have had distinct
  rollout timelines and constraints); a supported device in an unsupported
  region reports unavailable.
- **Device language** must be an Apple Intelligence-supported language.
  As of iOS 26.1, all four of our shipped cascade languages are covered —
  English, French, German, and Danish (Danish arrived in the 26.1
  eight-language expansion; 16 languages total). A user whose device is set
  to a language outside Apple's list still reports unavailable. Note the FM
  sample itself is English-prompted only — multilingual FM would require
  localized prompts/catalogs and per-language benchmark runs.

**Critical runtime consequence:** the user can toggle Apple Intelligence off
*while our app is running*. Production design must therefore treat
availability as a **per-turn condition, not a launch-time fact**. The sample
already behaves correctly: an in-flight failure maps to the standard fallback
result (never a crash, never a hung turn), and the landing screen re-checks
availability per render. Production code must keep both properties.

### 4.3 Model not ready — `.modelNotReady`

A transient state on fully eligible, enabled devices:

- First-time asset download after enabling Apple Intelligence.
- Re-download / migration after an OS update.
- The system may also decline while assets are being updated or under
  storage pressure it resolves itself.

Production handling: treat as "unavailable right now" and fall through to
the non-FM path for that turn. Do not queue, block, or retry-loop a user
turn against a downloading model. Recheck opportunistically (our per-render
check suffices).

### 4.4 Conditions that pass the availability check but fail at call time

Availability is necessary, not sufficient. The session can still fail
per-request, and production must absorb each of these exactly as the sample
does (map to fallback, log, never crash):

| Runtime condition | Trigger | Handling |
|---|---|---|
| **Guardrail refusal** | Framework safety layer declines the prompt or response. Our domain brushes health/hearing topics, so this is not hypothetical. | Same as OOS → fallback card |
| **Rate limiting** | Bursty request patterns (relevant to the serial benchmark and any future parallel use) | Serialize through the actor (already done); surface "thinking…" not an error |
| **Context window exceeded** | Pathologically long utterance (stateless sessions removed the accumulation cause) | One retry on a fresh session, then fallback |
| **Cancellation / interruption** | System pressure, app backgrounding mid-turn | Fallback; next turn is a fresh session anyway |
| **OS-update model drift** | Apple revs the model; same prompt, different behavior | Cannot be prevented — only detected: re-run the holdout benchmark on every OS release; reports are OS-stamped for exactly this reason |

### 4.5 The degradation ladder (production design)

The complete decision sequence a production integration must implement —
note that every rung lands on today's shipped behavior, which is what makes
the FM role safe:

```
Turn arrives
  ├─ Cascade classifies (always, every device) ──────────────► confident? act.
  └─ Cascade says out-of-scope / low confidence:
       ├─ FM available this turn?  ──── yes ──► FM answers the fallback turn
       │     └─ FM errors/refuses mid-call? ──► standard "can't help" card
       └─ no (ineligible / AI off / not ready / unsupported
              region or language) ────────────► standard "can't help" card
                                                (= exactly today's behavior)
```

---

## 5. Decision summary and next steps

| Decision | Status |
|---|---|
| Production classifier | **CoreML cascade** — unconditional |
| FM as primary/replacement classifier | **Rejected** — coverage, revocability, no confidence signal, no version control (§3) |
| FM as OOS-fallback responder on eligible devices | **Approved in principle**, gated on the §8 benchmark bars |
| FM as Tier-3 (semantic rescue) replacement on eligible devices | Deferred — revisit only if benchmark materially beats 89.4% |

**Next steps, in order:**

1. Run the holdout benchmark on ≥ 2 eligible devices (harness is built;
   ~6 minutes per run) and attach the OS-stamped reports to this document.
2. Pull the fleet device-model distribution → real eligible-coverage number.
3. If bars clear: spec the production fallback integration per §4.5,
   including per-turn availability checks and the error-absorption table in
   §4.4, plus a standing "re-benchmark on every iOS release" checklist item.
4. Keep the FM sample's field-findings discipline: every prompt edit is
   followed by a benchmark run before it merges.

**Caveat on external facts:** device-eligibility lists, regional rollout
status, and Apple Intelligence language support change with Apple's releases.
The specifics in §4 are accurate as of this report's writing and should be
re-verified against Apple's current documentation whenever this decision is
revisited.
