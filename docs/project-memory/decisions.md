# Architecture Decision Record (ADR)
_Last updated: 2026-06-20 | Engineering Director_

---

## ADR-001: Single `.playAndRecord` Audio Session Category
**Status**: Accepted  
**Date**: Prior to this session  
**Decision**: Use a single `.playAndRecord` / `.spokenAudio` session category for both mic input and TTS output, owned by `AudioSessionManager`. `ConversationSpeaker` only re-activates, never re-categorizes.  
**Rationale**: Category churn (`.record` ↔ `.playAndRecord`) left `AVSpeechSynthesizer` in a contested state, causing silent utterance drops on turn 2+.  
**Trade-off**: Cannot use `.measurement` mode for mic input (minimal signal processing). `.spokenAudio` is appropriate for speech.

---

## ADR-002: NLUEngine and IntentClassifierService as Actors
**Status**: Accepted  
**Date**: This session (feature/Adv2/AddSemanticUnderstanding-4)  
**Decision**: Convert both from `final class @unchecked Sendable` to `actor`. Call sites use plain `Task { await service.method() }`.  
**Rationale**: Actors provide off-main execution and automatic serialization. Eliminates `Task.detached` at call sites, structured concurrency preserved, race on shared `NLUEngine` handle fixed.  
**Trade-off**: All public methods are now `await`-only. Synchronous callers (e.g., `genaiURL()`) must be restructured.

---

## ADR-003: `deactivateSession: false` on TTS Handoff
**Status**: Accepted  
**Date**: Prior to this session  
**Decision**: When stopping recording to speak a TTS prompt, pass `deactivateSession: false` to `stopLiveTranscription()`. The recognizer and mic engine stop, but the shared audio session remains active.  
**Rationale**: Session deactivation/re-activation costs ~100ms per turn. Since TTS uses the same `.playAndRecord` category, re-activation is unnecessary.  
**Trade-off**: The audio session is never fully deactivated between turns; other apps' audio remains ducked.

---

## ADR-004: TTS Watchdog Timer (800ms)
**Status**: Accepted  
**Date**: Prior to this session  
**Decision**: Arm a generation-tracked watchdog Task in `ConversationSpeaker.speak()`. If `didStart` doesn't fire within 800ms, treat the utterance as silently dropped and fire `onCancel`.  
**Rationale**: `AVSpeechSynthesizer` can silently fire `didFinish` without `didStart`, leaving `isSpeaking = true` and the conversation deadlocked.  
**Trade-off**: An 800ms false-positive window. Extremely slow TTS startup (e.g., contested audio session) could trigger false recovery.

---

## ADR-005: Python Repository as Source of Truth
**Status**: Accepted  
**Decision**: All NLU logic, thresholds, schema, and behavioral specification originate in the Python repository. iOS must match Python outputs.  
**Rationale**: Single source for model training, evaluation, and schema evolution. iOS is a deployment target, not a design authority.  
**Implication**: Any behavioral change requires Python change first, then iOS port. Parity tests must cover all features.

---

## ADR-006: On-Device Inference (Offline-First)
**Status**: Accepted  
**Decision**: All classification runs on-device via CoreML. No network calls for NLU.  
**Rationale**: Hearing aid users require offline capability. Privacy: speech never leaves device. No infrastructure cost. Latency: ~10ms on-device vs ~100ms server round-trip.  
**Trade-off**: Model updates require app update. Schema changes require retraining + CoreML export + app update.

---

## ADR-007: Intent Interruption Threshold = 0.75
**Status**: Accepted  
**Decision**: A new intent during slot-filling requires confidence ≥ 0.75 to interrupt the pending flow. Matches Python `INTERRUPT_THRESHOLD`.  
**Rationale**: Base threshold (0.70) is too low to interrupt; an ambiguous utterance like "take medication" should answer a reminder slot, not start a new intent. 0.75 requires stronger signal.  
**Trade-off**: Genuine topic switches at 0.70–0.74 confidence are not detected.

---

## ADR-008: Isotonic Calibration for Confidence Scores
**Status**: Accepted (partially broken — see R20)  
**Decision**: Export per-class isotonic calibration maps from training. Apply during inference to align device confidence with server-calibrated probabilities.  
**Rationale**: Raw CoreML logits are miscalibrated vs. server's `CalibratedClassifierCV`. Without calibration, correct mid-confidence intents fall below the 0.70 threshold.  
**Current State**: Calibration maps are present in `intent_classifier_weights.json`. However, the `IntentClassifier.mlpackage` is missing its `logits` output, so calibration applies Swift-computed logits rather than CoreML logits. Must regenerate model.

---

## ADR-009: Slot Confidence Threshold Lower for Slot-Filling Intents (PENDING)
**Status**: Pending implementation  
**Decision**: Apply 0.60 confidence threshold for slot-filling intents (where prompts resolve ambiguity), vs 0.70 for fire-and-forget intents.  
**Rationale**: Python uses `slot_confidence_threshold = 0.60` from schema. A low-confidence slot-fill intent is still better than a GenAI fallback — the dialogue will clarify.  
**Action**: Implement in Phase 2 (Task 2.3.1).

---

## ADR-010: Back-Reference Resolution as Pre-Pass (PENDING)
**Status**: Pending implementation  
**Decision**: Before classification, check if the utterance matches a schema `back_reference.pattern`. If so, reuse stored parameters from previous fulfillment.  
**Rationale**: "Change back" and "remind me again" are common UX patterns. Forcing users through full slot-fill for these is poor UX and a parity gap.  
**Action**: Implement in Phase 3 (Tasks 3.1.1–3.1.3).
