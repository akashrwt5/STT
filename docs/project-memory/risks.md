# Risk Register
_Last updated: 2026-06-20 | Director: Engineering Director Agent_

## Severity: CRITICAL

| ID | Risk | Location | Status | Mitigation |
|----|------|----------|--------|------------|
| R01 | **NLUSession not actor-isolated** — `NLUSession` is a plain `final class` mutated from inside `NLUEngine` (an actor). A second concurrent `handle()` call can observe half-mutated session state after an `await` suspension point (actor reentrancy). | `NLUEngine.swift`, `NLUContext.swift` | 🔴 Open | Convert `NLUSession` to actor, or add `@unchecked Sendable` with documented single-owner invariant |
| R02 | **`FileCaptureService.isCancelled` is a bare Bool with no synchronization** — written from `stop()` (main thread), read from `streamFile()` (background task). Race condition on every file transcription. | `FileCaptureService.swift:30` | 🔴 Open | Wrap with `OSAllocatedUnfairLock` |
| R03 | **`AudioCaptureService.streamContinuation` unprotected** — written in `start()`, read in the tap closure running on the audio thread. Concurrent access without a lock. | `AudioCaptureService.swift:16` | 🔴 Open | Add lock or document strict single-call-to-start invariant |
| R04 | **Users can be trapped in slot-fill loops indefinitely** — no `MAX_SLOT_ATTEMPTS` equivalent. If entity extraction never succeeds (e.g., bad microphone, unexpected phrasing), the engine keeps re-prompting forever. | `NLUEngine.swift:handleSlotFilling` | 🔴 Open | Implement slot attempt counter with GenAI fallback at 3 failures |
| R05 | **Stale confirmation contexts can fire hours later** — no TTL-based expiry. A `confirm` context set at noon can trigger a yes/no handler when the user speaks at 3pm about something else. | `NLUContext.swift` | 🔴 Open | Add `createdAt: Date` + `ttlSeconds` to `NLUConversationContext`; check in `handle()` |

## Severity: HIGH

| ID | Risk | Location | Status | Mitigation |
|----|------|----------|--------|------------|
| R06 | **"yes, no worries" incorrectly returns `false`** — iOS yes/no detection lacks `_NO_IDIOMS` neutralization. Affirmative idioms containing "no" (no worries, no problem, no doubt) are misread as negation. | `NLUEngine.swift:yesNo()` | 🟠 Open | Add idiom list and neutralize before polarity scan |
| R07 | **Opportunistic slot scanning always uses fuzzy matching** — Python disables fuzzy on bulk scans (`fuzzy=False`). iOS always fuzzy-matches, risking false slot fills on incidental mentions. | `NLUEngine.swift:extractAllSlots` | 🟠 Open | Add `fuzzy: Bool` parameter to `EntityExtractor.extract()` |
| R08 | **Weak keyword (substring match) can interrupt a slot-fill flow** — Python suppresses interrupts triggered by a bare `contains` keyword hit. iOS has no such suppression. | `NLUEngine.swift:handleSlotFilling` | 🟠 Open | Track keyword tier in `ClassificationResult`; suppress in interrupt check |
| R09 | **`regex` and `regex_guarded` keyword rule types not implemented** — schema rules using these types are silently ignored on iOS. | `KeywordMatcher.swift` | 🟠 Open | Implement both types; test against existing schema entries |
| R10 | **`slot_confidence_threshold` not respected** — Python uses 0.60 for slot-filling intents (lower bar, prompts resolve ambiguity). iOS uses 0.70 for all intents, causing slot-fill intents to fall back to GenAI when they shouldn't. | `NLUEngine.swift:handleNewIntent` | 🟠 Open | Read `slot_confidence_threshold` from schema; apply when `cfg.slots.isEmpty == false` |
| R11 | **Back-references ("change back", "remind me again") not implemented** — common UX shortcut falls through to full slot-fill, requiring user to repeat all information. | `NLUEngine.swift` | 🟠 Open | Implement `_tryBackReference()` + `recordFulfillment()` + `getLastParams()` |
| R12 | **Recording start task not stored** — `startRecording()` spawns a Task that's never stored. Can't be cancelled if the user rapidly toggles or switches locale mid-start. | `LiveTranscriptionViewModel.swift:123` | 🟠 Open | Store as `recordingTask: Task<Void,Never>?`, cancel on re-entry |
| R13 | **Interrupt resume (after phone call) errors silently swallowed** — `try? await startLiveTranscription()` in interruption handler discards failures. UI stays in incorrect state. | `TranscriptionCoordinator.swift:366` | 🟠 Open | Propagate error to delegate |

## Severity: MEDIUM

| ID | Risk | Location | Status | Mitigation |
|----|------|----------|--------|------------|
| R14 | **Fuzzy match minimum length 3 chars (iOS) vs 5 (Python)** — enables false positives on short strings like "Car"/"care". | `EntityExtractor.swift` | 🟡 Open | Raise minimum to 5 chars to match Python |
| R15 | **Semantic threshold hardcoded (0.55)** — can't tune per deployment via schema. | `IntentClassifierService.swift` | 🟡 Open | Read from `NLUSchema.semanticThreshold` |
| R16 | **`cancelFileTranscription()` task not stored** — fire-and-forget; resources may not fully clean up if coordinator deallocates. | `TranscriptionCoordinator.swift:299` | 🟡 Open | Store as `cancellationTask` |
| R17 | **Session state bleeds across long user breaks** — no idle timeout (10 min in Python). A pending intent from yesterday can affect next-day usage. | `NLUContext.swift` | 🟡 Open | Add `lastActive: Date` to `NLUSession`; reset on idle > 10 min |
| R18 | **`@unchecked Sendable` on `AudioCaptureService`, `EntityExtractor`, `SemanticEmbedder` undocumented** — safety claim is correct but will break silently if mutable state is ever added. | Multiple | 🟡 Open | Add explicit safety comments on each |
| R19 | **30 Hz animation Timer creates 30 `Task {}` allocations/sec on main actor** | `LiveTranscriptionViewModel.swift:185` | 🟡 Open | Replace with `withAnimation` or `CADisplayLink` |
| R20 | **CoreML agent report pending** — CoreML inference pipeline not yet fully audited. | `IntentClassifierService.swift`, `SemanticEmbedder.swift` | 🟡 Pending | Awaiting CoreML agent output |

## Severity: LOW

| ID | Risk | Location | Status | Mitigation |
|----|------|----------|--------|------------|
| R21 | **No per-turn telemetry** — Python emits structured `nlu.decision` log per turn. iOS has no equivalent. Hard to debug production accuracy issues. | `NLUEngine.swift` | 🟢 Open | Add `os.log` structured telemetry per turn |
| R22 | **Entity extraction returns `String?` only** — loses confidence/span signal. Can't rank or threshold match quality. | `EntityExtractor.swift` | 🟢 Open | Return `EntityMatch(value, span, confidence)?` |
| R23 | **`tfidf_intent`/`tfidf_confidence` not captured in result** — can't audit which semantic rescues were genuine vs. false positives. | `IntentClassifierService.swift` | 🟢 Open | Add to `ClassificationResult` |
| R24 | **`TranscriptionCoordinator` is 400+ lines mixing multiple concerns** | `TranscriptionCoordinator.swift` | 🟢 Open | Extract file transcription, permission, and silence logic to separate types |
| R25 | **No error recovery / retry for transient failures** — asset download failure, analyzer restart, session activation failure all logged but not retried. | Multiple | 🟢 Open | Add exponential-backoff retry for recoverable errors |
