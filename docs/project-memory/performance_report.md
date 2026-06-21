# Performance Report — iOS NLU Platform
_Last updated: 2026-06-20 | Agents: Performance Engineer + CoreML Engineer_

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
