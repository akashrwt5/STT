# Stage 3 (semantic rescue) — what it would take to turn on

**Status: OFF, deliberately.** `semantic_rescue_enabled` is `false` in
`language_packs/en/platform.yaml`, so `runtime/cascade.json` ships
`{"id": "semantic", "enabled": false}` and no semantic head ships at all.

This document exists because turning it on looks like a one-line change and is
not. Someone tried the one-line version and the release build failed three ways;
the list below is what that cost, written down so the next attempt starts from
the real shape of the work.

Written against `pack-en-v1.0.48` and the VoiceAIKit tree at the time. Every
claim below is a file and line you can go read — if one no longer matches, trust
the code and fix this document.

---

## What Stage 3 is

The cascade has three stages (`runtime/cascade.json`):

| stage | what it does | state |
|---|---|---|
| `keyword` | declarative rules over the utterance | on |
| `tfidf` | TF-IDF vector → CoreML linear head → 57 logits | on |
| `semantic` | MiniLM sentence embedding → linear head → logits | **off** |

Stage 3 is a *rescue*: when Stage 2 lands below the fire threshold, an
independent recogniser gets a look. Two recognisers agreeing is stronger
evidence than one being confident, which is what `thresholds.agreement` (0.5)
encodes — the reference engine drops the fire bar to it when TF-IDF and the
semantic head land on the same real intent.

`SemanticHead.mlpackage` is **only the linear layer** — roughly 57×384 weights
plus a bias, about 92 KB. It consumes a 384-dimensional sentence embedding. It
does not produce one.

---

## Why it is off

Not a policy choice. The head as trained today cannot ship, and the runtime that
would consume it does not exist yet.

### The head fails its own contract in three places

Enabling the flag today produces exactly this, from the release build:

```
[stage 1] SCHEMA_INVALID        'embedder' unexpected / 'embedder_id' required
[stage 8] EMBEDDER_ID_MISMATCH  head 'onnx' vs manifest 'minilm-l6-v2'
[stage 8] HEAD_LABEL_MISMATCH   57 labels; stage 8 wants the intents plus OOS
```

Only the first is visible before the build stops. The other two were found by
running stage 8's comparison by hand.

**1. `embedder` is not `embedder_id`.** `train_semantic_head.py` writes:

```python
"embedder": "onnx",     # its own comment: "which embed path built this"
```

That records the *build path*. `embedder_id` means something else — the schema
defines it as the tie to "the exact encoder+vocab pair it was trained against",
and says why: a mismatch is the silent-wrong-vector-space bug class. A head
scored against embeddings from a different encoder produces confident,
meaningless answers.

**2. No OOS class.** The head trains on the 57 classifier labels. Stage 8 wants
`intents ∪ {oos_label}` — 58 — and `weights`/`bias` rows to match. A rescue
stage with no way to say "none of these" can only ever pick one of 57.

**3. Nothing to embed with.** `bundle.json` `models` has one family, `intent`.
There is no `embedder`. The head expects 384-dim vectors and the pack ships
nothing that produces them.

### The Swift runtime has no Stage 3

`PackClassifierAdapter.loadStage3()` (`Pack/Loader/PackEngineFactory.swift`) is,
in full:

```swift
func loadStage3() async {
    guard semanticEnabled else { return }
}
```

The guard is deliberate and documented — a host asking for a stage the pack
disables is asking for behaviour the report card was not measured under. What is
missing is everything after it: enabled or not, nothing loads.

And in the same file, both `ClassificationResult` returns hardcode
`semanticRescue: false`, so the pack path cannot produce a rescued result even
in principle.

Searching `Sources/VoiceAIKit` finds no MiniLM inference, no WordPiece
tokenizer, no pooling. The one `vocab.txt` reference is in
`OTA/Models/PackModelResolution.swift`, which resolves paths and does not run a
model.

---

## The size decision — settle this first

MiniLM-L6-v2 in CoreML fp16 is on the order of **45 MB**. Today's iOS pack is
**4.3 MB**.

```
pack today          4.3 MB
+ MiniLM           ~45   MB
                   ────────
                   ~50   MB
```

An order of magnitude, paid by every device on every OTA. That is a product
decision about download size, install time and memory — not a build flag — and
it should be answered before any of the engineering below is started, because a
"no" makes most of it moot.

If the answer is no, the alternative worth pricing is a server-side rescue for
low-confidence turns. That is a different design with a different privacy
posture (the utterance leaves the device), and ADR-004 makes that consent a
per-user, revocable runtime condition — which a fleet-wide signed pack cannot
express. Do not solve it by putting an endpoint in the pack; that was VIK-058.

---

## The work, in dependency order

Do not start at the bottom. The flag is last, and turning it on early is what
produced the failed build.

### 1. Trainer — `packages/buildtime/nlu_training/train_semantic_head.py`

Cheapest step, safe to do today, breaks nothing (no head ships while the stage
is off). Clears two of the three build blockers in advance.

- Emit `embedder_id` naming the actual encoder and its vocab — a stable
  identifier, versioned, e.g. `minilm-l6-v2-<rev>`. Not `"onnx"`.
- Add the OOS class to `labels`, with its row in `weights` and `bias`. Set
  `oos_label` explicitly rather than leaning on stage 8's `sys.oos` default.
- Keep the label set equal to the bundle's intents plus that OOS label. Stage 8
  compares them as sets.

### 2. Compiler / pack — only if the encoder ships

- Add a `models.embedder` entry whose `model_version` **exactly equals** the
  head's `embedder_id`. Stage 8 compares these two strings; that comparison is
  the whole point of the field.
- Ship the encoder and its WordPiece vocabulary as declared artifacts.
  `BundleDataLoader.verifyDeclaredArtifacts` refuses a pack that names a file it
  does not ship, so declaring is not optional.
- `compile_models` already ships `head.json` + `SemanticHead.mlpackage` once the
  stage is enabled — that part needs no change.

### 3. VoiceAIKit — the bulk of it

Nothing here exists yet.

| piece | note |
|---|---|
| WordPiece tokenizer | must match the encoder's vocab exactly; a tokenizer mismatch is silent, like the OOV class of bug |
| MiniLM CoreML load + inference | plus its ANE/CPU placement decision, as ADR-017 did for the intent head |
| Mean pooling + L2 normalisation | must match what the head was trained against |
| Head matmul → logits → softmax | its own temperature, if one is fitted |
| Threshold wiring | `thresholds.semantic` (0.4) and `thresholds.agreement` (0.5) are in every pack and read by nothing here — VIK-055 |
| `semanticRescue` | currently hardcoded `false` in two places in `PackEngineFactory` |
| `loadStage3` / `releaseStage3` | the lifecycle exists; the bodies do not |

Two ordering rules the reference engine follows, worth copying rather than
rediscovering:

- The OOV guard runs **before** rescue is attempted, so a turn blocked for
  unrepresentable input never reaches Stage 3. VoiceAIKit currently runs rescue
  inside `classifyAsync`, before the guard — noted in `NLUEngine.handleNewIntent`
  as a known difference that becomes a real divergence the day this is enabled.
- `agreement` is EVIDENCE STRENGTH, not a confidence. The reported confidence
  stays the model's calibrated probability; only the bar it must clear moves.
  Raising the score for corroborated turns instead would put a second scale back
  into the confidence field, which is the defect the ladder was rebuilt to
  remove.

### 4. Compatibility

- Declare the requirement in `required_runtime_features` (today `[]`), so an SDK
  without Stage 3 refuses a pack that needs it instead of silently ignoring it.
- The report card that gates release was measured with the stage **off**
  (`ResolvedPack.stageEnabled` says so). Turning it on changes what the pack
  does, so it needs its own measured report card — `holdout_accuracy`,
  `oos_recall`, `wrong_action_count` — not the current one carried forward.

### 5. Only now: the flag

Set `semantic_rescue_enabled: true` in `language_packs/en/platform.yaml`.

One flag drives everything: `compile_cascade` reads it for
`cascade.json`, and `compile_models` reads it to decide whether a head ships. No
second switch to keep in sync.

`tests/test_semantic_head_gating.py::test_content_keeps_the_semantic_stage_disabled`
will go red when you flip it. That is intentional — it is the reminder that the
steps above are done, and it should be updated in the same change that finishes
them.

---

## Quick reference

| thing | where | today |
|---|---|---|
| the flag | `language_packs/en/platform.yaml` → `semantic_rescue_enabled` | `false` |
| stage wiring | `runtime/cascade.json` → `semantic.enabled` | `false` |
| head shipping gate | `content_bundle.compile_models` | gated on the flag |
| head artifact | `models/semantic_head/shared/head.json` (+ `.mlpackage`) | not shipped |
| encoder | `bundle.json` → `models.embedder` | absent |
| thresholds | `runtime/policies.json` → `semantic` 0.4, `agreement` 0.5 | shipped, unread (VIK-055) |
| stage check | `ResolvedPack.stageEnabled(.semantic)` | works |
| load | `PackClassifierAdapter.loadStage3()` | empty body |
| rescue flag | `PackEngineFactory` `ClassificationResult` | hardcoded `false` |
| regression test | `tests/test_semantic_head_gating.py` | 3 tests, green |
