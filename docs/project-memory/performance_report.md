# Performance Report — iOS NLU Platform
_Last updated: 2026-06-22 | Agents: Performance Engineer + CoreML Engineer + Memory Diagnostics_
_Last updated: 2026-06-21 | Engineering Director_


## End-to-End Latency Budget (User speaks → First TTS audio)

| Stage | Typical | Worst Case | Notes |
|-------|---------|------------|-------|
| STT endpointing (silence window) | 500ms | 1000ms | Largest bottleneck; configurable |
| NLU inference (off-main, actor) | 10–20ms | 50ms | Stage 1+2; Stage 3 adds ~8ms |
| Mic teardown (recognizer drain) | 20–50ms | 100ms | `deactivateSession: false` saves ~100ms |
| TTS synthesizer startup | 100–200ms | 400ms | Voice load dominates |
| **Total** | **630–870ms** | **1650ms** | Dominated by STT endpointing |

_Source: `FIRST AUDIO` log measurements, 4-turn conversation (turns 2–4 post-fix: 27–35ms teardown)_

---

## CoreML Inference Performance

### Stage 2 — Intent Classifier

| Path | Latency | Notes |
|------|---------|-------|
| CoreML (ANE, A12+) | ~2ms | Primary path |
| CoreML (CPU fallback) | ~5ms | Older devices |
| Pure Swift JSON weights | ~8ms | Fallback if model missing |

**RESOLVED**: `IntentClassifier.mlpackage` now exposes `logits` output (pulled from remote 2026-06-20). Verified 3 outputs: `classProbability`, `logits`, `label`. Isotonic calibration now uses CoreML logits correctly.

### Stage 3 — MiniLM Semantic Rescue

| Step | Latency |
|------|---------|
| Tokenization | ~1ms |
| CoreML (ANE) embedding | ~6ms |
| Semantic head (pure Swift) | ~0.5ms |
| **Total Stage 3** | **~8ms** |

Stage 3 is optional; only activates on Stage 2 low-confidence results.

---

## Memory Profile — EXPERIMENTALLY VERIFIED 2026-06-21

> **This section supersedes all earlier estimates. Numbers below are measured via
> `task_info(TASK_VM_INFO)` MemoryProbe snapshots, not guesses.**

### Baseline at launch (before prewarm)
- `phys_footprint`: ~27 MB
- `anon dirty`: ~27 MB

### After prewarm completes (+98.5 MB dirty)

| Allocator | Resident Δ | Dirty Δ | Source |
|-----------|-----------|---------|--------|
| `MALLOC_SMALL` | +61.1 MB | +52.5 MB | CoreML weight copies (ANE buffers) + SpeechTranscriber internals |
| `MALLOC_LARGE` | +44.7 MB | +44.7 MB | Apple speech model + SpeechAnalyzer pipeline buffers |
| Other | ~+2.7 MB | ~+1.3 MB | Misc framework overhead |
| **Total** | **+136 MB resident** | **+98.5 MB dirty** | **fully on jetsam budget** |

### After first mic tap (post-prewarm)
- `phys_footprint Δ`: ~0 KB — **the tap itself costs nothing**
- Prewarm fully amortizes all framework allocation

### `AssetInventory.reserve` finding
The `reserve` call *reduces* memory by ~24.8 MB — it's a cleanup trigger that frees
transient model-loading parse buffers, not the cost source. The spike happens during
`SpeechTranscriber` init and `SpeechAnalyzer` construction before reserve is called.

---

## Critical Finding: Apple Speech Model Memory is Non-Evictable and Non-Releasable

**Experimentally confirmed 2026-06-21. Do not re-investigate without a new iOS major version.**

### The experiment
Four consecutive `SpeechAnalyzer = nil` / `SpeechTranscriber = nil` unload cycles
measured zero memory reclamation:

| Unload attempt | phys_footprint Δ | anon dirty Δ |
|---------------|-----------------|-------------|
| 1 | +0 KB | +0 KB |
| 2 | +0 KB | +0 KB |
| 3 | +0 KB | +0 KB |
| 4 | +0 KB | +0 KB |

Reload after unload: +112 KB — nothing was reloaded because nothing was freed.

### Why
`SpeechTranscriber` and `SpeechAnalyzer` are public-facing handles only. The underlying
ANE-prepared model weights live in `libSpeechRecognition.dylib`'s **process-global cache**.
The framework amortizes the expensive model load across the process lifetime. Nilling the
handles releases the handles, not the weights.

### Consequences for this app
1. **Prewarm is a one-way ratchet.** Once +98.5 MB is paid it stays for the process lifetime. There is no reclaim path short of app kill.
2. **Lazy-load does not reduce peak memory.** It only delays when the user pays the cost. Loading on first tap means cold-start latency AND the +98.5 MB — worst of both worlds.
3. **Unload/reload patterns are futile.** Any "memory management" of the speech model via nilling Swift objects has zero effect on the underlying framework allocation.

### Memory breakdown by controllability

| Component | Dirty MB | Controllable? | Notes |
|-----------|---------|--------------|-------|
| Apple speech model (ANE weights, process-global) | ~45–50 MB | ❌ No | Lives in `libSpeechRecognition.dylib`; cannot be freed |
| SpeechTranscriber + SpeechAnalyzer buffers | ~15–20 MB | ❌ No | Apple framework internals |
| MiniLM CoreML + SemanticHead (ours) | ~15–20 MB | ✅ Deferrable | Load on first Stage 3 invocation |
| IntentClassifier CoreML + vocab + idf (ours) | ~10–15 MB | ⚠️ Needed | Required every classification; keep warmed |
| Misc framework overhead | ~3–5 MB | ❌ No | |
| **Irreducible floor (mic live)** | **~85–90 MB** | | Apple's model + our classifier |
| **Current total** | **~100–105 MB** | | With MiniLM deferred |

### Recommendation
For a voice-first hearing-aid companion app: **prewarm at launch and accept the 100 MB.**
The comparison class is Apple Dictation and Siri — both pay the same floor. On iPhone 12+
(4 GB RAM), 130 MB is ~3.2% of RAM and well below any practical jetsam threshold for a
foreground app.

If STT were optional/occasional, the right call would be to skip prewarm and show a
"Loading speech recognition…" spinner on first use. For this app, prewarm is correct.

---

## Warmup Strategy (Current — Correct as of 2026-06-21)

`activate()` fires two parallel background tasks:
1. `IntentClassifierService.shared.warmUp()` — CoreML ANE graph specialization
2. `coordinator.prewarm()` — full speech model setup (locale → install/reserve → Transcriber + Analyzer)

`startTranscribing()` awaits the in-flight prewarm task before checking the cached pair,
preventing a race where a fast first-tap competes with prewarm on `AssetInventory.reserve`
(concurrent reserve on the same locale can stall — that was the original first-tap hang).

First tap after prewarm: **~0 ms setup cost** (confirmed by MemoryProbe Δ ≈ 0 KB on tap).

---

## Audio Pipeline Performance

| Step | Cost | Notes |
|------|------|-------|
| Buffer deep-copy (4096 frames) | ~0.5ms per buffer | Essential for correctness |
| RMS power (VAD) | ~0.1ms per buffer | Negligible |
| Format conversion (BufferConverter) | ~0.5ms first, ~0ms cached | Reuses converter |
| Feed to SpeechAnalyzer | ~1ms per buffer | Framework call |

**Total audio pipeline overhead**: ~2ms per 4096-frame buffer (~85ms of audio at 48kHz). Acceptable.

---

## Main Thread Load

| Source | Frequency | Cost |
|--------|-----------|------|
| 30 Hz animation Timer | 33ms | Creates Task per tick; ~1ms per tick total |
| NLU apply() | Per utterance | <1ms (pure state updates) |
| Coordinator state transitions | Per state change | <1ms |
| TTS delegate callbacks | Per utterance | <1ms |

**Concern**: The 30 Hz Timer spawns a `Task { @MainActor }` 30 times/second. Replace with `withAnimation` or `TimelineView`.

---

## Startup Latency (App Launch → Ready to Transcribe)

| Step | Time | Thread |
|------|------|--------|
| `IntentClassifierService` init (JSON parse — labels, vocab, idf only) | ~60ms | Main (singleton init) |
| CoreML model load (IntentClassifier + SemanticHead) | ~30ms | Main |
| MiniLM model + vocab | ~250ms | Background (Task) |
| CoreML graph compilation (warmup) | ~150ms | Background |
| Speech model prewarm (locale + reserve + Analyzer) | ~800–2000ms | Background |
| **Total blocking (main thread)** | **~90ms** | Reduced from ~145ms (coef deferred) |
| **Total to full ready** | **~1–2s** | Background — prewarm dominates |

---

## Known Optimizations in Place

| Optimization | Impact | Where |
|-------------|--------|-------|
| Single `.playAndRecord` audio category | ~100ms saved per turn | `AudioSessionManager` |
| `deactivateSession: false` on TTS handoff | ~100ms saved per turn | `LiveTranscriptionViewModel` |
| Off-main NLU inference (actor) | No UI blocking | `NLUEngine` |
| MiniLM loaded in background Task | No startup blocking | `IntentClassifierService` |
| CoreML + speech model prewarm on `activate()` | Cold-start on first tap avoided | `LiveTranscriptionViewModel` |
| Prewarm stored as Task; `startTranscribing` awaits it | No race on AssetInventory.reserve | `SpeechRecognitionService` |
| `isStarting` flag; double-tap guard | No competing setup tasks | `LiveTranscriptionViewModel` |
| LogReg coef/intercept deferred (lazy load) | ~5–25 MB not allocated when CoreML healthy | `IntentClassifierService` |
| Buffer converter reused per session | ~0.5ms saved per buffer | `BufferConverter` |
| `isSpeaking` guard drops TTS-contaminated audio | Avoids spurious NLU calls | `LiveTranscriptionViewModel` |

---

## Optimization Opportunities (Not Yet Implemented)

| Opportunity | Estimated Gain | Effort | Notes |
|------------|----------------|--------|-------|
| Defer MiniLM to first Stage 3 invocation | ~15–20 MB dirty RAM | S | Trade: first semantic rescue pays ~200ms ANE compile |
| Shorter silence endpointing window (0.8s vs 1.5s) | ~400ms/turn | S | Config change |
| Start NLU on high-confidence partials (speculative) | ~200ms/turn | L | Architectural |
| Replace 30Hz Timer with `TimelineView` | CPU reduction | S | |
| Async `IntentClassifierService` init | ~90ms startup | M | |
>>>>>>> 8c346964c91faaafe2ad93c1ad137e04a933ab24

---

## End-to-End Latency Budget (User speaks → First TTS audio)

| Stage | Typical | Worst Case | Notes |
|-------|---------|------------|-------|
| STT endpointing (silence window) | 500ms | 1000ms | Largest bottleneck; configurable |
| NLU inference (off-main, actor) | 10–20ms | 50ms | Stage 1+2; Stage 3 adds ~8ms |
| Mic teardown (recognizer drain) | 20–50ms | 100ms | `deactivateSession: false` saves ~100ms |
| TTS synthesizer startup | 100–200ms | 400ms | Voice load dominates |
| **Total** | **630–870ms** | **1650ms** | Dominated by STT endpointing |

_Source: `FIRST AUDIO` log measurements, 4-turn conversation (turns 2–4 post-fix: 27–35ms teardown)_

---

## CoreML Inference Performance

### Stage 2 — Intent Classifier

| Path | Latency | Notes |
|------|---------|-------|
| CoreML (ANE, A12+) | ~2ms | Primary path |
| CoreML (CPU fallback) | ~5ms | Older devices |
| Pure Swift JSON weights | ~8ms | Fallback if model missing |

**CRITICAL FINDING**: The bundled `IntentClassifier.mlpackage` is missing the `logits` output. As a result:
- `coreMLLogits()` always returns `nil`
- Isotonic calibration silently falls back to the pure-Swift TF-IDF logit computation
- The CoreML model is only used for `classProbability` (probabilities), not logits
- Confidence calibration is subtly wrong: isotonic maps are applied to Swift-computed logits, not CoreML's logits

**Fix required**: Regenerate `IntentClassifier.mlpackage` with `export_coreml.py` to expose the `logits` output. Verify 3 outputs: `classProbability`, `logits`, `label`.

### Stage 3 — MiniLM Semantic Rescue

| Step | Latency |
|------|---------|
| Tokenization | ~1ms |
| CoreML (ANE) embedding | ~6ms |
| Semantic head (pure Swift) | ~0.5ms |
| **Total Stage 3** | **~8ms** |

Stage 3 is optional; only activates on Stage 2 low-confidence results.

---

## Memory Profile

> ⚠️ **The table below underestimates real memory cost by ~5×.** Empirical
> measurement (see [Memory Investigation — CoreML Lifecycle](#memory-investigation--coreml-lifecycle-2026-06-2122)
> below) shows the NLU stack adds **~100 MB phys_footprint** when fully loaded,
> not 27 MB. The discrepancy is the ANE-resident weight replication and
> activation arenas, which are not visible from on-disk file sizes alone.

| Component | Size on disk | Load Time | Real cost in process |
|-----------|------|-----------|---------|
| IntentClassifier.mlpackage | 320 KB | ~30ms | ~3–4 MB after init + warmUp |
| MiniLM embedder (.mlpackage) | 16 MB | ~200ms (background) | **~85 MB dirty after ANE compile** |
| minilm-vocab.txt | 228 KB | ~50ms (background) | ~1.5 MB retained Swift dict |
| intent_classifier_weights.json | 692 KB | ~50ms sync | ~2 MB retained (labels/vocab/idf) |
| SemanticHead.mlpackage | 96 KB | ~5ms | ~1–3 MB |
| nlu_schema.json | 50 KB | ~5ms sync | ~200 KB |
| **Total NLU stack** | **~17 MB** | | **~95–100 MB phys_footprint** |

---

## Warmup Strategy

**Current**: Fire-and-forget `Task(priority: .userInitiated)` in `activate()`.
- Pre-compiles CoreML graphs (ANE specialization on A12+)
- Pre-loads MiniLM vocab
- Runs one "hello" prediction to warm caches

**Gap**: No way to know if warmup completed before first utterance. If user speaks immediately, first classification pays cold-start cost.

**Recommendation**: Track warmup completion in a flag; fall back to Stage 1+2 only on first turn if Stage 3 not yet warm.

---

## Audio Pipeline Performance

| Step | Cost | Notes |
|------|------|-------|
| Buffer deep-copy (4096 frames) | ~0.5ms per buffer | Essential for correctness |
| RMS power (VAD) | ~0.1ms per buffer | Negligible |
| Format conversion (BufferConverter) | ~0.5ms first, ~0ms cached | Reuses converter |
| Feed to SpeechAnalyzer | ~1ms per buffer | Framework call |

**Total audio pipeline overhead**: ~2ms per 4096-frame buffer (~85ms of audio at 48kHz). Acceptable.

---

## Main Thread Load

| Source | Frequency | Cost |
|--------|-----------|------|
| 30 Hz animation Timer | 33ms | Creates Task per tick; ~1ms per tick total |
| NLU apply() | Per utterance | <1ms (pure state updates) |
| Coordinator state transitions | Per state change | <1ms |
| TTS delegate callbacks | Per utterance | <1ms |

**Concern**: The 30 Hz Timer spawns a `Task { @MainActor }` 30 times/second. Each allocation is minor but creates unnecessary pressure. Replace with `withAnimation` or `TimelineView`.

---

## Startup Latency (App Launch → Ready to Classify)

| Step | Time | Thread |
|------|------|--------|
| `IntentClassifierService` init (JSON parse) | ~100ms | **Main thread** (singleton init) |
| CoreML model load | ~30ms | Main thread |
| Semantic head JSON load | ~15ms | Main thread |
| MiniLM model + vocab | ~250ms | Background (Task.detached) |
| CoreML graph compilation (warmup) | ~150ms | Background |
| **Total blocking** | **~145ms** | Main thread |
| **Total to full ready** | **~400ms** | Background |

**Concern**: ~145ms of JSON parsing on the main thread during singleton init. Acceptable for now; could be moved to an async init if startup jank is observed.

---

## Known Optimizations Already in Place

| Optimization | Impact | Where |
|-------------|--------|-------|
| Single `.playAndRecord` audio category | ~100ms saved per turn | `AudioSessionManager` |
| `deactivateSession: false` on TTS handoff | ~100ms saved per turn | `LiveTranscriptionViewModel` |
| Off-main NLU inference (actor) | No UI blocking | `NLUEngine` |
| MiniLM loaded in background Task | No startup blocking | `IntentClassifierService` |
| CoreML warmup on `activate()` | Cold-start on first turn avoided | `LiveTranscriptionViewModel` |
| Buffer converter reused per session | ~0.5ms saved per buffer | `BufferConverter` |
| `isSpeaking` guard drops TTS-contaminated audio | Avoids spurious NLU calls | `LiveTranscriptionViewModel` |

---

## Optimization Opportunities (Not Yet Implemented)

| Opportunity | Estimated Gain | Effort |
|------------|----------------|--------|
| Shorter silence endpointing window (0.8s vs 1.5s) | ~400ms/turn | S — config change |
| Start NLU on high-confidence partials (speculative) | ~200ms/turn | L — architectural |
| Keep `SpeechRecognitionService` warm between turns | ~50ms/turn | M — session reuse |
| Stream NLU start during final STT processing | ~100ms/turn | L — pipeline change |
| Replace 30Hz Timer with `TimelineView` | CPU reduction | S |
| Async `IntentClassifierService` init | ~145ms startup | M |

---

## Memory Investigation — CoreML Lifecycle (2026-06-21/22)

A multi-day root-cause investigation into the +100 MB phys_footprint observed
after NLU prewarm. **Critical findings — read before redesigning the NLU
lifecycle or adding new CoreML models.**

### Background

Observed: app launch footprint ~30 MB → after NLU prewarm ~150 MB. The +100 MB
appears stuck — does not return after teardown. Initial assumption was that
Apple's Speech framework was the culprit; this turned out to be wrong.

### Methodology

Built three diagnostic tools, all DEBUG-gated:

1. **`STT/STT/STT/Services/MemoryProbe.swift`** — VM region walker using Mach
   APIs (`task_info(TASK_VM_INFO)` for process totals, `vm_region_recurse_64`
   for per-region breakdown bucketed by `user_tag`). Captures `phys_footprint`
   (jetsam-relevant), `resident_size`, anonymous-dirty, file-backed-clean, and
   per-allocation-tag deltas.
2. **Lifecycle buttons** in `STTTestView` header (`IC+` / `IC-` / `S3+` / `S3-`)
   to manually load/release the IntentClassifier and its Stage 3 components
   while measuring memory before/after each operation.
3. **Deinit logging** on `IntentClassifierService`, `SemanticEmbedder`, and
   `SemanticClassifier` to verify Swift-level deallocation actually runs.

The singleton `IntentClassifierService.shared` was temporarily removed and the
service moved to coordinator-owned `var intentClassifier: IntentClassifierService?`
ownership so the actor could actually deinit when released. All NLU call sites
were temporarily disabled (TEMP-NLU-OFF markers) so no path could hold a
phantom reference.

### Three hypotheses tested

| Hypothesis | Description |
|---|---|
| **A** — CoreML runtime cache | `MLModel.deinit` runs, but ANE-resident weights / compiled graphs / activation arenas stay in CoreML's process-scoped cache |
| **B** — Strong reference retention | Some object (singleton, closure, Task, observer) still holds the model, preventing Swift-level deinit |
| **C** — App-owned memory | Models deallocate cleanly but app retains large data structures (vocab dict, embedding cache, etc.) |

### Apple Speech Framework — ruled out as the major contributor

A minimal app (Speech only, no NLU) loaded the iOS 26 SpeechAnalyzer +
SpeechTranscriber for en-IN and measured:

```
prewarm.before: phys=25.77 MB
prewarm.after:  phys=24.67 MB   (Δ -1.09 MB)
```

**Apple Speech costs ~0 MB phys_footprint.** The 16 MB en-IN model is mmap'd
clean from the system asset store — resident grows ~100 MB (file-backed) but
phys_footprint barely moves. The user's original hypothesis from the start of
the investigation was correct. Earlier verdicts that blamed Speech were a
measurement artifact from concurrent CoreML warmup running in parallel with
Speech prewarm during `LiveTranscriptionViewModel.activate()`.

### Stage-by-stage memory cost (measured)

Each stage's contribution isolated by disabling the others in
`IntentClassifierService.init` (using `TEMP-NLU-STAGE*-OFF` markers).

| Configuration | phys_footprint at idle | Δ vs baseline |
|---|---|---|
| App baseline (no NLU loaded) | ~22 MB | — |
| Stage 1 only (KeywordMatcher + Stage 1+2 JSON) | ~32 MB | +10 MB |
| Stage 1 + Stage 2 (CoreML IntentClassifier) | ~35 MB | +13 MB |
| **Stage 1 + Stage 2 + Stage 3 (full)** | **~130 MB** | **+108 MB** |

**Stage 3 (MiniLM-L6-v2) is responsible for ~95% of the NLU memory budget.**

### Stage 3 load/release experiment — the critical test

With the singleton removed, deinit logging in place, and NLU disabled at all
call sites (so nothing could phantom-retain), the manual lifecycle test:

```
[MemoryProbe] before Init IC:   phys=26.7 MB
[MemoryProbe] after  Init IC:   phys=30.4 MB    (Δ +3.7 MB)

[MemoryProbe] before Stage3 Load: phys=28.3 MB
[MemoryProbe] after  Stage3 Load: phys=198.1 MB  (Δ +169.8 MB peak)
  Top-tag deltas (after S3 Load):
    MALLOC_LARGE: +83.9 MB / 5 new regions / 100% dirty   ← MiniLM weight replication
    MALLOC_SMALL: +62.8 MB / 17 new regions / 100% dirty  ← ANE activation arenas

(idle for some seconds — iOS naturally reclaimed ~69 MB of transient buffers)

[MemoryProbe] before Stage3 Release: phys=128.9 MB
[Deinit] SemanticEmbedder (MLModel + vocab released)    ← FIRED
[Deinit] SemanticClassifier (MLModel released)          ← FIRED
[MemoryProbe] after  Stage3 Release: phys=128.7 MB      (Δ -128 KB)

(idle for some seconds — iOS naturally reclaimed another ~37 MB)

[MemoryProbe] before Free IC: phys=92.1 MB
[Deinit] IntentClassifierService                        ← FIRED
[MemoryProbe] after  Free IC: phys=92.1 MB              (Δ -0 KB)
```

### Findings

1. **All three deinits fire.** Swift-level deallocation is clean. The singleton
   was removed; ownership chain leaves no stranded references when the
   coordinator drops its `intentClassifier`. → **Hypothesis B is conclusively
   ruled out.**

2. **Releasing the Swift handles does not synchronously return memory.** The
   tap-time delta on both `S3-` (-128 KB) and `IC-` (0 KB) is essentially noise.
   `MLModel.deinit` runs, but CoreML's process-scoped ANE/Espresso runtime
   cache survives. → **Hypothesis A confirmed.**

3. **iOS does reclaim some memory asynchronously.** Between snapshots (during
   idle periods), phys_footprint dropped 69 MB and then another 37 MB without
   any user action. This is iOS draining purgeable memory, malloc returning
   cached pages, and CoreML doing late cleanup of transient buffers. None of
   this can be triggered on demand from app code.

4. **A persistent ~65 MB floor survives even full IntentClassifier teardown.**
   Final phys_footprint after every Swift object has deinit'd: 92.1 MB. Baseline:
   26.7 MB. The +65 MB gap is the CoreML/Espresso/ANE runtime cache, which
   only releases on process termination (or extreme memory pressure jetsam).

5. **App-owned memory is minor.** The WordPiece vocab dict (~1.5 MB) is the
   only material app-retained allocation; it deallocates with `SemanticEmbedder`.
   Hypothesis C contributes <2 MB, swamped by A.

### Final root-cause confidence

| Hypothesis | Confidence | Status |
|---|---|---|
| A — CoreML/Espresso/ANE process-wide runtime cache | **~90%** | Confirmed by experiment |
| B — Strong reference retention | **0%** | Ruled out — all deinits fire |
| C — App-owned memory (vocab dict, retained JSON state) | **~5%** | Minor contribution (~2 MB) |
| iOS lazy reclaim path (delayed page returns) | **~5%** | Real but partial; cannot be triggered on demand |

### Why on-disk size doesn't predict in-memory size

The MiniLM `.mlpackage` is 16 MB on disk (mostly `weights/weight.bin`). In
memory it becomes ~85 MB dirty. The expansion comes from CoreML's multi-stage
runtime layout:

| Allocation | Where | Size | Reason |
|---|---|---|---|
| 1. mmap of `weight.bin` | file-backed clean | ~16 MB | Initial bundle read |
| 2. ANE-format weight replica | dirty | ~16 MB | ANE requires tiled/packed weight layout in its own accessible memory; CoreML reformats and copies |
| 3. Per-layer activation arenas | dirty | ~10–20 MB | 6-layer transformer × max_len=64 × 384 dim × FP16 outputs |
| 4. Attention Q/K/V scratch | dirty | ~5–10 MB | Materialized per inference; cached for reuse |
| 5. CoreML runtime overhead | dirty | ~3–8 MB | Compiled ANE kernels, dispatch tables, MLDispatchQueue |

Rule of thumb for transformer models on Apple Neural Engine: expect
**3–4× on-disk size as in-memory dirty cost** after first prediction.

### What this rules out as a memory-saving strategy

The experiment definitively rules out the following as viable optimizations
for reclaiming Stage 3 memory once loaded:

- ❌ **Per-mic-tap load/release cycles** — Swift teardown succeeds but memory doesn't return synchronously; user pays cold-start cost without saving memory
- ❌ **Idle-timeout teardown** — same reason
- ❌ **Per-view-lifecycle ownership** — view dismiss → VM deinit → service deinit, but ANE cache outlives all Swift objects
- ❌ **Releasing `MLModel` refs proactively** — releases the Swift wrapper, not the CoreML cache
- ❌ **Making the service non-singleton** — necessary for proper deinit but does not by itself reclaim memory
- ❌ **`onDisappear` / `onBackground` Swift-side cleanup** — same boundary problem

### What remains as a viable memory-saving lever

| Strategy | Memory saved | Implementation cost |
|---|---|---|
| **Lazy-load Stage 3** on first Stage 2 low-confidence result | Up to ~100 MB until first miss; once loaded, ratcheted for process lifetime | S — refactor `classifyAsync` to defer `SemanticEmbedder()` / `SemanticClassifier()` instantiation |
| **Quantize MiniLM to INT8** (re-export `.mlpackage`) | ~50–60 MB (halves the ANE weight replica + activation precision) | M — re-run `export_coreml.py` with int8 quantization, validate accuracy |
| **Smaller embedder architecture** (distilled 64–128-dim) | ~70–80 MB | L — train and export new model |
| **Drop Stage 3 entirely** (Stages 1+2 only) | ~100 MB | S — measure rescue trigger rate first to bound accuracy loss |
| **Server-side semantic rescue** for low-confidence Stage 2 | ~100 MB local | M — network call, privacy review, latency budget |

**Recommended next step**: measure how often Stage 2 returns sub-threshold
(`conf < 0.70`) on a representative utterance set. If <5%, dropping Stage 3
entirely is the highest-leverage win. If 10–20%, lazy-load is the right call.
If >20%, Stage 3 is doing important work and quantization is the path forward.

### Architecture decision recorded

The singleton `IntentClassifierService.shared` was removed during this
investigation to enable proper deinit testing. After the experiment, the
service ownership pattern of choice is:

- **Production**: keep a `lazy var` instance owned by the view model that needs
  it; restore singleton only if multiple owners need to share the loaded state
  (in which case the +100 MB is paid once across owners).
- **Diagnostic build**: keep the coordinator-owned `var intentClassifier: IntentClassifierService?`
  pattern so memory profiling tools can drop the reference deterministically.

The diagnostic Load/Free buttons (`IC+`/`IC-`/`S3+`/`S3-`) and the
`MemoryProbe` utility remain in the codebase, DEBUG-gated, for future regression
testing when CoreML version changes or new on-device models are added.

### Files added during this investigation

- `STT/STT/STT/Services/MemoryProbe.swift` — DEBUG-only VM region walker
- `[Deinit]` prints in `IntentClassifierService.swift`, `SemanticEmbedder.swift`, `SemanticClassifier.swift`
- `loadStage3()` / `releaseStage3()` / `initIntentClassifier()` / `freeIntentClassifier()` on `TranscriptionCoordinator`
- Header lifecycle buttons in `STTTestView`
- `TEMP-NLU-OFF` and `TEMP-NLU-STAGE*-OFF` markers tagging the temporarily-disabled NLU call sites (grep these to restore production NLU flow)

### Open questions for future work

1. Does iOS reclaim CoreML cache under simulated memory-pressure
   notifications (`os_proc_available_memory()` drops)? Untested.
2. Does `MLModelConfiguration.computeUnits = .cpuOnly` produce a smaller
   persistent floor than `.all`? May trade memory for latency.
3. Would explicitly compiling the model with smaller `maxSequenceLength`
   reduce activation arena size?

These would clarify whether there are additional levers without changing
the model architecture.
