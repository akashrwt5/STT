# NLU Parity Report: Python (Source of Truth) vs. iOS
_Last updated: 2026-06-20 | Agent: NLU Engine Engineer_

## Status Legend
- ✅ Full parity
- ⚠️ Partial parity (behavioural gap exists)
- ❌ Missing in iOS

---

## Critical Gaps (ship-blocking)

| # | Feature | Python | iOS | User Impact |
|---|---------|--------|-----|-------------|
| 1 | `_NO_IDIOMS` neutralization in yes/no detection | ✅ | ❌ | "yes, no worries" → returns `false` instead of `true`; cancels confirmed intents |
| 2 | Slot attempt tracking (`MAX_SLOT_ATTEMPTS = 3`) | ✅ | ❌ | Users trapped in unanswerable slot-fill loops forever |
| 3 | Back-reference resolution (`_try_back_reference`) | ✅ | ❌ | "change back" / "remind me again" fall through to full slot-fill |
| 4 | Context TTL-based expiry (wall-clock, 90s) | ✅ | ❌ | Stale confirmation contexts can fire hours after being set |
| 5 | Session idle timeout (reset after 10 min) | ✅ | ❌ | Stale `pendingIntent` bleeds across long user breaks |

---

## High-Priority Gaps (significant behavioural difference)

| # | Feature | Python | iOS | User Impact |
|---|---------|--------|-----|-------------|
| 6 | Fuzzy disable on opportunistic slot scans (`fuzzy=False` in `_extract_all_slots`) | ✅ | ❌ | iOS may fuzzy-match incidental words as slot values when opportunistically scanning |
| 7 | Weak-keyword interrupt suppression (`last_keyword_tier == "contains"`) | ✅ | ❌ | iOS may abandon a slot-fill flow on a bare substring mention like "ask about translate" |
| 8 | `regex` and `regex_guarded` keyword rule types | ✅ | ❌ | Advanced keyword rules in schema silently not matched on iOS |
| 9 | `slot_confidence_threshold` (0.60 for slot intents, 0.70 for fire-and-forget) | ✅ | ❌ | iOS uses fixed 0.70 for all intents, rejecting valid low-confidence slot triggers |
| 10 | Fuzzy match minimum length: 5 chars (Python) vs 3 chars (iOS) | ✅ | ⚠️ | iOS fuzzy-matches shorter strings, risking false positives (e.g., "Car"/"care") |

---

## Medium-Priority Gaps (missing polish/configurability)

| # | Feature | Python | iOS | Notes |
|---|---------|--------|-----|-------|
| 11 | Schema-driven semantic threshold (`schema["semantic_threshold"]`) | ✅ | ❌ | iOS hardcodes 0.55; can't tune per deployment |
| 12 | Entity `extract()` returns `(value, span, confidence)` | ✅ | ❌ | iOS returns `String?` only; no match quality signal |
| 13 | `last_fulfilled` / `get_last_params()` for parameter reuse | ✅ | ❌ | Required by back-references; also needed for telemetry |
| 14 | `record_fulfillment()` / `prev_memory` tracking | ✅ | ❌ | Required by back-references |
| 15 | `tfidf_intent` / `tfidf_confidence` in result | ✅ | ❌ | iOS doesn't capture Stage 2 prediction before semantic override |
| 16 | Per-turn structured telemetry (`_log_decision`) | ✅ | ❌ | No per-turn stage/latency/confidence telemetry in iOS |

---

## Confirmed Parity ✅

| Feature | Notes |
|---------|-------|
| Confirmation yes/no word-boundary matching | Identical logic; negation wins on conflict |
| Uncertain phrase detection ("not sure", "maybe", etc.) | Identical list |
| Priority order: CONFIRMATION > SLOT_FILL > CLASSIFY | Identical |
| Intent interruption threshold (0.75) | Identical |
| TF-IDF unigram+bigram tokenization | Identical |
| L2 normalization | Identical |
| Isotonic calibration (iOS has it; Python uses plain softmax — iOS is *better*) | iOS improvement |
| MiniLM tokenization (WordPiece, CLS/SEP, max 64 tokens) | Identical |
| Semantic rescue mean-pool + L2 normalize | Identical |
| `sys.date-time` day anchoring via `partialDateTime` | Identical |
| `sys.date-time` `timeExplicit` / `explicitDay` flags | Identical |
| Carrier phrase stripping for open topics | Identical (same 6 patterns) |
| Context lifespan decrement on fresh-intent turns | Identical |
| Slot filling advance logic (`advanceSlots`) | Identical |
| Open entity free-text fallback | Identical |

---

## Implementation Priority Order

1. **Gap #1** — `_NO_IDIOMS` (5 lines, high impact)
2. **Gap #2** — Slot attempt tracking (20 lines, prevents user lock-in)
3. **Gap #9** — `slot_confidence_threshold` from schema (5 lines, affects recall)
4. **Gap #4** — TTL-based context expiry (30 lines, prevents ghost confirmations)
5. **Gap #5** — Session idle timeout (15 lines, prevents state bleed)
6. **Gap #3** — Back-references (largest: ~80 lines, requires session memory additions)
7. **Gaps #6, #7** — Fuzzy parameter + weak-keyword suppression (20 lines each)
8. **Gap #8** — regex/regex_guarded keyword types (40 lines)
9. **Gaps #11–16** — Schema-driven config + telemetry (incremental)
