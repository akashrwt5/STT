# Performance Report — iOS NLU Platform
_Last updated: 2026-06-21 | Engineering Director_

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

| Component | Size | Load Time | Resident |
|-----------|------|-----------|---------|
| IntentClassifier.mlpackage | ~2MB | ~30ms | ~4MB compiled |
| MiniLM embedder | ~17MB | ~200ms (background) | ~20MB |
| minilm-vocab.txt | ~800KB | ~50ms (background) | ~1MB |
| intent_classifier_weights.json | ~500KB | ~50ms sync | ~2MB parsed |
| nlu_schema.json | ~50KB | ~5ms sync | ~200KB |
| **Total NLU stack** | **~20MB** | | **~27MB resident** |

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
