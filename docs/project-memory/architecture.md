# iOS NLU Platform — Architecture Document
_Last updated: 2026-06-20 | Agent: Principal iOS Architect_

## System Overview

A fully offline, production-grade NLU platform replacing Dialogflow. All inference runs on-device via CoreML. The Python repository is the **source of truth** for model training, schema, and behavioral specification. The iOS implementation must match Python outputs exactly.

---

## Layer Diagram

```
┌─────────────────────────────────────────────────────────┐
│                     SwiftUI Views                        │
│         LiveTranscriptionView / FileTranscriptionView    │
└────────────────────┬────────────────────────────────────┘
                     │ owns @State
┌────────────────────▼────────────────────────────────────┐
│              ViewModels (@Observable, @MainActor)        │
│   LiveTranscriptionViewModel / FileTranscriptionViewModel│
│   • Conversation state machine                           │
│   • STT→NLU→TTS orchestration                          │
└───────┬───────────────────────────┬────────────────────┘
        │ owns                      │ owns
┌───────▼──────────┐    ┌──────────▼──────────────────────┐
│ TranscriptionCoordinator          │  NLUEngine (actor)   │
│ (@Observable, @MainActor)         │  • Multi-turn dialogue│
│ • STT lifecycle                   │  • Slot filling       │
│ • Permissions                     │  • Confirmation       │
│ • Locale mgmt                     │  • Interruption       │
│ • Silence detection               │                       │
└───────┬───────────┘    └──────────┬──────────────────────┘
        │                           │ uses
┌───────▼───────────┐    ┌──────────▼──────────────────────┐
│ AudioSessionManager│    │  IntentClassifierService (actor) │
│ (@MainActor)       │    │  Stage 1: KeywordMatcher         │
│                    │    │  Stage 2: CoreML TF-IDF+LogReg   │
│ SpeechRecognition  │    │  Stage 3: MiniLM semantic rescue │
│ Service (@MainActor│    └─────────────────────────────────┘
│                    │
│ AudioCaptureService│    ┌─────────────────────────────────┐
│ FileCaptureService │    │  EntityExtractor                 │
└────────────────────┘    │  ConversationSpeaker (@MainActor)│
                          └─────────────────────────────────┘
```

---

## Module Boundaries

### Public API Surface (what callers can use)
```
TranscriptionCoordinator      — sole STT entry point
NLUEngine                     — multi-turn dialogue actor
NLUResponse                   — typed result enum
IntentClassifierService.shared — classification actor
AudioRoute                    — current audio route info
TranscriptionState/Result/Error — domain types
SilenceDetectionConfiguration  — VAD tuning
```

### Internal (implementation details, not for callers)
```
AudioSessionManager, AudioCaptureService, FileCaptureService
SpeechRecognitionService, BufferConverter, SilenceDetector
KeywordMatcher, SemanticEmbedder, SemanticClassifier
EntityExtractor, NLUSession, NLUSchema, ConversationSpeaker
```

---

## Concurrency Model

| Component | Isolation | Reason |
|-----------|-----------|--------|
| `TranscriptionCoordinator` | `@MainActor` | Drives SwiftUI observable state |
| `SpeechRecognitionService` | `@MainActor` | Delegates back to coordinator |
| `AudioSessionManager` | `@MainActor` | AVAudioSession delegate callbacks |
| `ConversationSpeaker` | `@MainActor` | AVSpeechSynthesizerDelegate callbacks |
| `LiveTranscriptionViewModel` | `@MainActor` | SwiftUI @Observable |
| `NLUEngine` | `actor` | Off-main inference; serializes session state |
| `IntentClassifierService` | `actor` | Off-main CoreML inference; singleton |
| `AudioCaptureService` | `@unchecked Sendable` | Tap closure runs on audio thread |
| `EntityExtractor` | `@unchecked Sendable` | Immutable after init |
| `SemanticEmbedder` | `@unchecked Sendable` | Immutable model + vocab |

### Key Invariant
The `await` at actor boundaries is the hop point. `@MainActor` code calling `await nlu.handle()` automatically runs the body on NLUEngine's executor (off-main) and returns to main on completion. No `Task.detached` needed for this.

---

## 3-Stage Intent Classification Pipeline

```
User Utterance
      │
      ▼
┌─────────────────────────────────────────────┐
│  Stage 1: KeywordMatcher (sync, ~0ms)        │
│  • Exact match: 0.97 confidence              │
│  • Contains match: 0.85 confidence           │
│  • TODO: regex, regex_guarded types          │
└──────────────────┬──────────────────────────┘
      hit?         │ no hit
      ├────────────┘
      │ miss → Stage 2
      ▼
┌─────────────────────────────────────────────┐
│  Stage 2: CoreML TF-IDF + LogReg (~2ms)     │
│  Primary: IntentClassifier.mlpackage        │
│  Fallback: intent_classifier_weights.json   │
│  + Isotonic calibration for confidence      │
└──────────────────┬──────────────────────────┘
      conf ≥ 0.70? │ no (conf < threshold or OOS)
      ├────────────┘
      │ low confidence → Stage 3
      ▼
┌─────────────────────────────────────────────┐
│  Stage 3: MiniLM Semantic Rescue (~8ms)     │
│  Optional: degrades gracefully if absent    │
│  Threshold: 0.55 (TODO: make schema-driven) │
└──────────────────┬──────────────────────────┘
      rescued?     │ no
      ├────────────┘
      │ → GenAI fallback URL
      ▼
   NLUResponse
```

---

## Multi-Turn Dialogue State Machine (NLUEngine)

```
New Utterance
      │
      ▼
┌─────────────────────────────────────────────┐
│  Priority 1: Active Confirmation?           │
│  (context with active lifespan set)         │
└──────────────────┬──────────────────────────┘
      yes          │ no
      │            ▼
      │  ┌─────────────────────────────────────┐
      │  │  Priority 2: Pending Intent?         │
      │  │  (slot filling in progress)          │
      │  └──────────────────┬──────────────────┘
      │        yes          │ no
      │        │            ▼
      │        │  ┌──────────────────────────────┐
      │        │  │  Priority 3: Classify         │
      │        │  │  (fresh intent)               │
      │        │  └──────────────────────────────┘
      │        │
      │        ▼
      │  [Re-classify to detect interruption]
      │  If new intent ≥ 0.75 confidence:
      │    → .interrupted(cancelledIntent, newResult)
      │  Else:
      │    → fill slot, advance to next prompt or fulfill
      │
      ▼
   NLUResponse (prompt | confirm | fulfill | fallback | interrupted)
```

---

## STT→NLU→TTS Conversation Loop

```
User speaks
    │
    ▼ (SpeechRecognitionService)
didReceiveFinalResult(text)
    │
    ▼ [guard: !isSpeaking]  ← drops audio captured during TTS
NLUEngine.handle(text)  — runs on actor executor (off-main)
    │
    ▼ (back on @MainActor)
apply(NLUResponse)
    │
    ├─ .prompt / .confirm ──→ speakSerialized(question)
    │                              │
    │                              ├─ stopRecording(deactivateSession: false)
    │                              ├─ await waitForTeardown()
    │                              └─ speaker.speak(question)
    │                                        │
    │                              onFinish ─┘
    │                              handleSpeechFinished()
    │                              startRecording()  ← restart mic for user's answer
    │
    └─ .fulfill / .fallback ──→ speakSerialized(message) or show card
                                 (no mic restart — conversation done)
```

---

## Audio Session Strategy

Single persistent `.playAndRecord` / `.spokenAudio` category shared by mic and TTS.

**Why**: Previously `.record`/`.measurement` for mic and `.playAndRecord` for TTS caused "category churn" — `AVSpeechSynthesizer` silently dropped the second utterance (fired `didFinish` without `didStart`). One category eliminates churn.

**Trade-off**: Cannot use `.measurement` mode (minimal signal processing). `.spokenAudio` provides appropriate signal processing for speech.

**TTS handoff**: `stopLiveTranscription(deactivateSession: false)` stops the recognizer without deactivating the session, saving ~100ms per turn.

---

## Missing Abstractions (Architecture Debt)

| Missing Protocol | Needed For | Blocks Testing |
|-----------------|------------|----------------|
| `AudioSessionManaging` | Mock in coordinator tests | Yes |
| `SpeechRecognitionServicing` | Mock STT in coordinator tests | Yes |
| `ConversationSpeaking` | Mock TTS in VM tests | Yes |
| `EntityExtracting` | Swap entity parser implementation | No |
| `ResourceLoading` | Inject test bundles | Yes |
| `ClassificationStage` | Pluggable pipeline stages | No |
