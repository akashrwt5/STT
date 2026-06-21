# Implementation Plan — iOS NLU Platform
_Last updated: 2026-06-20 | Engineering Director_
_Branch: feature/Adv2/AddSemanticUnderstanding-4_

## Delivery Phases

---

## Phase 1: Critical Safety & Correctness (Sprint 1)
_Target: Zero data races. No user-facing regressions._

### 1.1 Fix Race Conditions (Risk R01–R03)

**Task 1.1.1** — `NLUSession` isolation  
- File: `STT/Services/NLU/NLUContext.swift`  
- Add `@unchecked Sendable` conformance with documented safety comment  
- OR convert to actor (larger change, do if time allows)  
- Effort: S (1h)

**Task 1.1.2** — `FileCaptureService.isCancelled` synchronization  
- File: `STT/Audio/FileCaptureService.swift:30`  
- Replace `private var isCancelled = false` with `OSAllocatedUnfairLock(initialState: false)`  
- Effort: S (30min)

**Task 1.1.3** — `AudioCaptureService.streamContinuation` protection  
- File: `STT/Audio/AudioCaptureService.swift`  
- Add re-entrancy guard on `start()`, or wrap continuation access with lock  
- Effort: S (1h)

### 1.2 Fix Yes/No Detection Parity (Risk R06, Gap #1)

**Task 1.2.1** — Add `_NO_IDIOMS` neutralization  
- File: `STT/Services/NLU/NLUEngine.swift:yesNo()`  
- Add idiom list: `["no worries", "no problem", "no doubt", "no biggie", "no probs", "no sweat", "not a problem"]`  
- Strip idioms from scan string before polarity check  
- Effort: S (30min)  
- Test: "yes, no worries" → `true`; "no worries" alone → `nil` (uncertain); "no" → `false`

### 1.3 Slot Attempt Escape Hatch (Risk R04, Gap #2)

**Task 1.3.1** — Add `slotAttempts` to `NLUSession`  
- File: `STT/Services/NLU/NLUContext.swift`  
- Add `var slotAttempts: Int = 0`  

**Task 1.3.2** — Implement attempt tracking in `handleSlotFilling`  
- File: `STT/Services/NLU/NLUEngine.swift`  
- Increment when awaited slot still unfilled after turn  
- Reset to 0 on progress  
- At `slotAttempts >= 3`: call `session.resetSlotFilling()`, return `.fallback`  
- Effort: M (2h)

### 1.4 Store Recording Task (Risk R12)

**Task 1.4.1** — Store `startRecording` task  
- File: `STT/ViewModels/LiveTranscriptionViewModel.swift`  
- `private var recordingTask: Task<Void, Never>?`  
- Cancel on re-entry  
- Effort: S (30min)

---

## Phase 2: Parity Gaps — High Priority (Sprint 2)
_Target: Behavioral parity with Python on all common flows._

### 2.1 Context TTL-Based Expiry (Risk R05, Gap #4)

**Task 2.1.1** — Add TTL to `NLUConversationContext`  
- File: `STT/Services/NLU/NLUContext.swift`  
- Add `createdAt: Date` and `ttlSeconds: TimeInterval?`  
- Add `isExpired(at now: Date) -> Bool`

**Task 2.1.2** — Expire contexts at turn start  
- File: `STT/Services/NLU/NLUEngine.swift:handle()`  
- Call `session.expireContexts(at: Date())` before priority check  
- Effort: M (2h)

### 2.2 Session Idle Timeout (Risk R17, Gap #5)

**Task 2.2.1** — Track `lastActive` in `NLUSession`  
- Add `var lastActive: Date = Date()`  
- Update on every `handle()` call  
- In `handle()`: if `Date().timeIntervalSince(lastActive) > 600`, call `resetAll()`  
- Effort: S (1h)

### 2.3 Slot Confidence Threshold from Schema (Gap #9, Risk R10)

**Task 2.3.1** — Read `slot_confidence_threshold` from schema  
- File: `STT/Services/NLU/NLUSchema.swift`  
- Add `slotConfidenceThreshold: Double` (default 0.60)  
- File: `STT/Services/NLU/NLUEngine.swift:handleNewIntent()`  
- Use `schema.slotConfidenceThreshold` when `cfg.slots.isEmpty == false`  
- Effort: S (1h)

### 2.4 Fuzzy Matching Minimum Length Fix (Gap #10)

**Task 2.4.1** — Raise minimum from 3 to 5 chars  
- File: `STT/Services/NLU/EntityExtractor.swift`  
- Change minimum length guard from `3` to `5`  
- Effort: XS (15min)

### 2.5 Fuzzy Disable Parameter (Gap #6)

**Task 2.5.1** — Add `fuzzy: Bool = true` to `extract()`  
- File: `STT/Services/NLU/EntityExtractor.swift`  
- Gate Levenshtein path behind parameter  
- File: `STT/Services/NLU/NLUEngine.swift:extractAllSlots()`  
- Pass `fuzzy: false` for opportunistic (non-awaited) slot scanning  
- Effort: S (1h)

### 2.6 Weak-Keyword Interrupt Suppression (Gap #7, Risk R08)

**Task 2.6.1** — Track keyword tier in classification result  
- File: `STT/Services/IntentClassifierService.swift`  
- Add `keywordTier: KeywordTier?` to `ClassificationResult` (`exact`, `contains`, `regex`, `regexGuarded`)  
- File: `STT/Services/KeywordMatcher.swift`  
- Return tier alongside label/confidence

**Task 2.6.2** — Suppress in interrupt check  
- File: `STT/Services/NLU/NLUEngine.swift:handleSlotFilling()`  
- Add `&& probe.keywordTier != .contains` to interrupt condition  
- Effort: M (2h)

### 2.7 Schema-Driven Semantic Threshold (Gap #11)

**Task 2.7.1** — Add `semanticThreshold` to `NLUSchema`  
- File: `STT/Services/NLU/NLUSchema.swift`  
- Read from schema JSON, default 0.55  
- File: `STT/Services/IntentClassifierService.swift`  
- Accept threshold at init or via property (needs NLUEngine to pass it through)  
- Effort: M (2h)

---

## Phase 3: Back-References & Advanced Features (Sprint 3)
_Target: Full parity with Python engine.py._

### 3.1 Back-Reference Resolution (Gap #3, Risk R11)

**Task 3.1.1** — Add fulfillment memory to `NLUSession`  
- `var lastFulfilled: [String: [String: String]] = [:]` — maps intent → last params  
- `var prevMemory: String?` — last `MemoryName` value  
- `func recordFulfillment(_ intent: String, params: [String: String])`  
- `func getLastParams(_ intent: String) -> [String: String]?`

**Task 3.1.2** — Add `back_reference` to `NLUSchema` / `IntentDef`  
- Read `back_reference.pattern`, `back_reference.source`, `back_reference.slot`

**Task 3.1.3** — Implement `tryBackReference()` in `NLUEngine`  
- Call as pre-pass before classification in `handle()`  
- Sources: `prev_memory`, `last_fulfilled`  
- Effort: L (4h)

### 3.2 Regex & regex_guarded Keyword Types (Gap #8, Risk R09)

**Task 3.2.1** — Implement `regex` match type in `KeywordMatcher`  
- Compile patterns from schema at init  
- Match against utterance, return 0.75 confidence  

**Task 3.2.2** — Implement `regex_guarded` match type  
- Compile both `pattern` and `not_regex`  
- Only match if `pattern` matches AND `not_regex` does NOT match  
- Return 0.90 confidence  
- Effort: M (3h)

### 3.3 Entity Extraction Match Quality (Gap #12)

**Task 3.3.1** — Return `EntityMatch` struct instead of `String?`  
```swift
struct EntityMatch {
    let value: String
    let span: Range<String.Index>?
    let confidence: Double  // 1.0 exact, 0.95 synonym, 0.60–0.90 fuzzy
}
```
- Update all call sites  
- Effort: M (3h)

---

## Phase 4: Architecture & Testability (Sprint 4)
_Target: Production-grade testability and observability._

### 4.1 Missing Protocol Abstractions

**Task 4.1.1** — Extract `AudioSessionManaging` protocol  
**Task 4.1.2** — Extract `ConversationSpeaking` protocol  
**Task 4.1.3** — Inject via constructor instead of concrete init  

### 4.2 Per-Turn Telemetry

**Task 4.2.1** — Add `NLUTelemetry` struct + logging in `NLUEngine.handle()`  
- Fields: intent, confidence, stage, latencyMs, semanticRescue, interruptedIntent  
- Log via `os.log` to `com.stt.module` / `NLU.Decision`

### 4.3 `TranscriptionCoordinator` Decomposition

**Task 4.3.1** — Extract permission logic to `PermissionChecker`  
**Task 4.3.2** — Extract file transcription to `FileTranscriptionSession`  
**Task 4.3.3** — Keep coordinator as thin orchestrator  

### 4.4 Task Lifecycle Fixes

**Task 4.4.1** — Store `cancelFileTranscription` task (Risk R16)  
**Task 4.4.2** — Propagate errors from interruption-resume task (Risk R13)  
**Task 4.4.3** — Replace 30 Hz Timer with `CADisplayLink` or animation binding (Risk R19)

---

## Phase 5: CoreML Audit (Sprint 5)
_Pending CoreML agent report — to be filled once available._

---

## Parity Test Plan

After each phase, run parity tests against the Python engine:

```
Input utterance → Python NLUEngine.handle() → NLUResult
Input utterance → iOS NLUEngine.handle()    → NLUResponse

Compare:
  - type (CONFIRM/PROMPT/FULFILL/FALLBACK matches case)
  - intent label
  - action
  - parameters (slots)
  - message
  - confidence (within ±0.05 tolerance)
```

Test scenarios to cover:
1. Single-turn intent (fire-and-forget)
2. Multi-slot flow (2+ prompts before fulfillment)
3. Intent interruption mid-slot-fill
4. Confirmation (yes/no) flow
5. Back-reference ("change back", "remind me again")
6. Yes/no idiom detection ("yes, no worries")
7. Slot attempt escape (3 failed extractions)
8. Context TTL expiry (set context, wait > 90s mock, new turn)
9. Session idle reset (gap > 10 min mock, stale state cleared)
10. Semantic rescue activation (low-confidence Stage 2 → Stage 3 fires)
