# Project Progress Tracker
_Last updated: 2026-06-20 | Engineering Director_

---

## Agent Analysis: COMPLETE ✅
All 5 specialist agents have reported. Shared memory artifacts written.

| Agent | Domain | Status | Key Finding |
|-------|--------|--------|-------------|
| Principal iOS Architect | Architecture | ✅ Complete | 400-line coordinator, missing protocol abstractions, DI gaps |
| NLU Engine Engineer | Python↔iOS Parity | ✅ Complete | 16 parity gaps; 5 critical; back-references + slot attempts missing |
| CoreML Integration Engineer | Inference Pipeline | ✅ Complete | **CRITICAL**: `logits` output missing from bundled model; isotonic calibration silently broken |
| Speech Pipeline Engineer | STT→NLU→TTS | ✅ Complete | Pipeline design sound; 5 potential stuck-state scenarios documented |
| Swift Concurrency + Performance | Races & Latency | ✅ Complete | 2 real race conditions (FileCaptureService, AudioCaptureService); actor reentrancy risk |

---

## Delivered This Session ✅

| Commit | Description | Branch |
|--------|-------------|--------|
| `ba806bd` | Convert NLUEngine + IntentClassifierService to actors; remove Task.detached | `feature/Adv2/AddSemanticUnderstanding-4` |
| `13653cb` | Intent interruption handling during slot-filling (parity gap #closing) | `feature/Adv2/AddSemanticUnderstanding-4` |

---

## Phase 1 — Critical Safety & Correctness

| Task | Description | Status | Priority |
|------|-------------|--------|----------|
| 1.1.1 | NLUSession isolation documentation | 🔴 Not started | CRITICAL |
| 1.1.2 | FileCaptureService.isCancelled race | 🔴 Not started | CRITICAL |
| 1.1.3 | AudioCaptureService.streamContinuation race | 🔴 Not started | CRITICAL |
| 1.2.1 | _NO_IDIOMS in yes/no detection | 🔴 Not started | HIGH |
| 1.3.x | Slot attempt tracking (MAX=3) | 🔴 Not started | HIGH |
| 1.4.1 | Store recording task | 🔴 Not started | MEDIUM |

**CoreML BLOCKER (Phase 1 addendum)**:
| Task | Description | Status | Priority |
|------|-------------|--------|----------|
| CM-1 | Regenerate IntentClassifier.mlpackage with logits output | ✅ Done (pulled from remote) | CRITICAL |
| CM-2 | Verify 3 outputs: classProbability, logits, label | ✅ Done (verified) | CRITICAL |
| CM-3 | Add logging when coreMLLogits() falls back | 🔴 Not started | MEDIUM |

---

## Phase 2 — High-Priority Parity Gaps

| Task | Description | Status |
|------|-------------|--------|
| 2.1.x | Context TTL-based expiry | 🔴 Not started |
| 2.2.1 | Session idle timeout (10 min) | 🔴 Not started |
| 2.3.1 | slot_confidence_threshold from schema | 🔴 Not started |
| 2.4.1 | Fuzzy min length: 3→5 chars | 🔴 Not started |
| 2.5.1 | fuzzy: Bool parameter on extract() | 🔴 Not started |
| 2.6.x | Weak-keyword interrupt suppression | 🔴 Not started |
| 2.7.1 | Schema-driven semantic threshold | 🔴 Not started |

---

## Phase 3 — Back-References & Advanced Features

| Task | Description | Status |
|------|-------------|--------|
| 3.1.x | Back-reference resolution | 🔴 Not started |
| 3.2.x | regex + regex_guarded keyword types | 🔴 Not started |
| 3.3.1 | EntityMatch struct (value + span + confidence) | 🔴 Not started |

---

## Phase 4 — Architecture & Testability

| Task | Description | Status |
|------|-------------|--------|
| 4.1.x | Protocol abstractions for AudioSession, TTS | 🔴 Not started |
| 4.2.1 | Per-turn NLU telemetry | 🔴 Not started |
| 4.3.x | TranscriptionCoordinator decomposition | 🔴 Not started |
| 4.4.x | Task lifecycle fixes | 🔴 Not started |

---

## Parity Gap Status

| Gap | Description | Severity | Status |
|-----|-------------|----------|--------|
| #1 | _NO_IDIOMS yes/no | Critical | 🔴 Open |
| #2 | Slot attempt tracking | Critical | 🔴 Open |
| #3 | Back-references | Critical | 🔴 Open |
| #4 | Context TTL expiry | Critical | 🔴 Open |
| #5 | Session idle timeout | Critical | 🔴 Open |
| #6 | Fuzzy disable on bulk scans | High | 🔴 Open |
| #7 | Weak-keyword interrupt suppression | High | 🔴 Open |
| #8 | regex/regex_guarded keywords | High | 🔴 Open |
| #9 | slot_confidence_threshold | High | 🔴 Open |
| #10 | Fuzzy min length 3→5 | High | 🔴 Open |
| Intent Interruption | Interrupt detection in slot-fill | Critical | ✅ **CLOSED** (commit 13653cb) |

---

## Shared Memory Files

| File | Status |
|------|--------|
| `docs/project-memory/architecture.md` | ✅ Written |
| `docs/project-memory/decisions.md` | ✅ Written |
| `docs/project-memory/implementation_plan.md` | ✅ Written |
| `docs/project-memory/parity_report.md` | ✅ Written |
| `docs/project-memory/performance_report.md` | ✅ Written |
| `docs/project-memory/risks.md` | ✅ Written |
| `docs/project-memory/progress.md` | ✅ Written |

---

## 2026-07-12 — Claude Code repo setup (branch: claude/repo-setup-token-efficiency-1245h1)

Branched from `claude/multilingual-nlu-status-check-s7ggcw` @ `5d48994` (its tip; no other
divergence). Added: root + IntentKit + VoiceIntentKit `CLAUDE.md`, `.claude/settings.json`
(permissions + hook), web SessionStart hook, `scripts/validate_resources.py`,
`.claude/agents/` (swift-reviewer, nlu-resource-auditor), `.gitignore` (untracked xcuserdata).
No app/package source or resource files were modified.
