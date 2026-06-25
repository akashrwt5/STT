# Multilingual NLU — Localized Prompts & Cross-Language Slot Filling

**Status:** PLAN / SPEC — **DO NOT IMPLEMENT until explicitly approved ("go ahead").**
**Branch:** `claude/coreml-temperature-ios`
**Owner persona:** Principal ML Engineer (on-device NLU, calibration, server↔device parity) + Swift/iOS.
**Related:** `docs/MULTILINGUAL_NLU_IMPLEMENTATION.md` (the model-variant work, already shipped),
`docs/MULTILINGUAL_TEST_RESOURCE_WIRING.md` (test-target wiring).

---

## 0. Problem statement

Today, switching to the multilingual Core ML model upgrades **intent recognition** for
French/German/etc., but every other part of the conversation stays English:

- the follow-up question ("When should I remind you?") is asked in English,
- the spoken fulfillment ("Reminder created.") is English,
- the yes/no detection only understands English words,
- date/number/enum slot parsing only understands English (a French date reply is not extracted).

Goal: **the assistant prompts and parses in the language the user is actually speaking**, while
preserving the existing server↔iOS (and future Android) parity contract and the temperature-scaling
calibration contract.

---

## 1. How English works today (ground truth)

Nothing *generates* `nlu_schema.json` / `nlu_entities.json` — they are **hand-authored JSON config
files** in `STT/STT/Resources/`. They contain two distinct kinds of content:

### 1.1 `nlu_schema.json` — the conversation script
- **Structure (language-neutral):** intents (`reminders.add`, `Cmd.MemoryChange`, `Cmd.SendMessage`),
  their slots (`name`, `entity` ref, `required`), `action`, follow-up `context`/`lifespan`.
- **Strings (language-specific):** slot `prompt`, `fulfillment`, follow-up `prompt` + branch
  `fulfillment`, and the `affirmative` / `negative` word lists.

### 1.2 `nlu_entities.json` — how slot values are recognized
- **Enum entities** (`memory`, `recurrence`, `remind`): data tables of `canonical_value → [synonyms]`.
  Canonical value (left) is a stable internal key / action parameter. Synonyms (right) are "what a
  user says." Flags: `fuzzy` (Levenshtein fallback), `open` (free-text allowed), `automated_expansion`.
- **System entities** (`sys.date-time`, `sys.number-integer`): only `{"type":"system"}` in JSON — **no
  data**. The actual parsing is **code**: `EntityExtractor.extractDateTime` (~300 lines) + `extractNumber`,
  a faithful Swift port of the server's Python `entities.py` rule engine.

### 1.3 Hidden English assumptions in code (not in JSON)
These are English literals embedded directly in Swift and must also be externalized:
- `NLUEngine.uncertain` — ["not sure","maybe","dunno",…]
- `NLUEngine.noIdioms` — ["no worries","no problem",…] (polite-negatives stripped before yes/no scan)
- `NLUEngine.carrierPatterns` — regexes that strip "remind me to", "please", "set a reminder to" to
  derive an open topic.
- `EntityExtractor`: `weekdays`, day anchors (`tomorrow`/`today`/`tonight`), period words
  (`morning`/`afternoon`/…), `numberWords`/`wordNums`, `am/pm`, relative units (`in N minutes`),
  idiom forms (`half past`, `quarter to`), and the `timePatterns` used by `stripDateTime`.

**Parity contract:** `EntityExtractor.extractDateTime` carries the comment *"Keep the two in sync — the
on-device result must match the server."* The server's `entities.py` is the source of truth. Any change
here must change both, and be proven equal by fixtures.

---

## 2. Core principle — separate THREE axes that are conflated today

| Axis | Controls | Keyed by | Mechanism |
|---|---|---|---|
| **Model variant** | which classifier scores intent | model family | `NLUVariant` + factory (exists) |
| **Conversation language** | prompts, fulfillments, yes/no, carrier phrases | BCP-47 locale | per-language string pack |
| **Entity grammar** | date/number/enum parsing | BCP-47 locale | per-language lexicon + shared engine |

**Rule: variant ≠ language.** The multilingual *model* serves many languages; the *language* for
prompts and grammar is a separate input. A French user = `model: multilingual`, `language: fr`. Do NOT
add `.french`/`.german` cases to `NLUVariant` — that re-couples model and language.

**Language source of truth:** the ASR transcription locale (`TranscriptionCoordinator.currentLocale`).
The user is literally speaking that language. Prompts/grammar follow the ASR locale; the Picker keeps
selecting only the *model* variant.

**DI discipline (unchanged from current architecture):** no `if language ==` / `if variant ==`
branches inside `NLUEngine`, `EntityExtractor`, or any service. Language is **data injected via the
factory**. Adding a language = drop in JSON files + fixtures, author zero new Swift types.

---

## 3. Artifact design — structure / strings / grammar as separate files

Authored and owned in the **IntentClassifier repo (server = source of truth)**, vendored to STT (and
later Android), exactly like the model weights.

```
data/nlu/
  schema.structure.json          # LANGUAGE-NEUTRAL: intents → slots/entity refs/actions/contexts/thresholds
  strings/
    strings.en.json              # prompts, fulfillments, affirmative[], negative[], uncertain[], no_idioms[], carrier_patterns[]
    strings.fr.json
    strings.de.json
  entities/
    enums.en.json                # per-language synonyms; canonical keys stay English
    enums.fr.json
    enums.de.json
  datetime/
    lexicon.en.json              # tokens + grammar flags (see 3.3)
    lexicon.fr.json
    lexicon.de.json
```

### 3.1 `schema.structure.json` (write once)
Prompts/fulfillments become **string IDs**, not literals:
```json
{
  "version": 3,
  "intents": {
    "reminders.add": {
      "slots": [
        {"name": "recurrence", "entity": "recurrence", "required": false, "prompt_id": null},
        {"name": "name",       "entity": "remind",      "required": true,  "prompt_id": "reminder.name"},
        {"name": "date-time",  "entity": "sys.date-time","required": true, "prompt_id": "reminder.when"}
      ],
      "fulfillment_id": "reminder.done",
      "action": "reminders.add"
    }
  }
}
```
`confidence_threshold` and the slot-filling `interrupt_threshold` move here too, but as objects that
**may be overridden per language** (see §6 calibration).

### 3.2 `strings.<lang>.json` (translate per language)
```json
{
  "language": "fr",
  "prompts":      { "reminder.name": "Que voulez-vous qu'on vous rappelle ?",
                    "reminder.when": "Quand dois-je vous le rappeler ?" },
  "fulfillments": { "reminder.done": "Rappel créé." },
  "affirmative":  ["oui","ouais","ok","d'accord","envoyer","confirmer","vas-y"],
  "negative":     ["non","annuler","stop","jamais","laisse tomber"],
  "uncertain":    ["je ne sais pas","peut-être","aucune idée"],
  "no_idioms":    ["pas de souci","pas de problème"],
  "carrier_patterns": ["^\\s*rappelle[- ]moi\\s+(?:de|d')?\\s*", "^\\s*s'il te plaît\\s+"]
}
```

### 3.3 `enums.<lang>.json` (per-language synonyms; English canonical keys)
```json
{
  "remind": {
    "type": "enum", "open": true, "fuzzy": true,
    "values": {
      "Take Medication": ["prendre mon traitement","prendre mes médicaments","prendre mes cachets"],
      "Drink Water":      ["boire de l'eau"]
    }
  }
}
```
> Canonical keys (`"Take Medication"`) are **never translated** — they are action params. Only the
> right-hand phrasings are localized, and they must be **native-sourced**, not dictionary translations.

### 3.4 `lexicon.<lang>.json` — the hard one: tokens + grammar flags
The date engine becomes **language-neutral code driven by this data**:
```json
{
  "language": "de",
  "weekdays": ["montag","dienstag","mittwoch","donnerstag","freitag","samstag","sonntag"],
  "day_anchors": { "today": ["heute"], "tomorrow": ["morgen"], "day_after_tomorrow": ["übermorgen"] },
  "periods": { "morning": {"words":["morgen","vormittag"],"hour":8}, "evening": {"words":["abend"],"hour":18} },
  "number_words": { "neun": 9, "zehn": 10, "...": 0 },
  "relative_units": { "minute":["minute","minuten"], "hour":["stunde","stunden"], "day":["tag","tage"] },
  "grammar": {
    "default_clock": "24h",
    "ampm_inference": false,
    "half_past_semantics": "german_next_hour",   // "halb neun" = 08:30
    "quarter_expressions": { "quarter_past": ["viertel nach"], "quarter_to": ["viertel vor"] },
    "decimal_separator": ","
  }
}
```
**Why flags, not just word lists:** date grammar differs *structurally*, not only lexically. The engine
reads `grammar.*` flags to choose the right rule; it never branches on the language string. Examples the
flags must capture: German `halb` (counts to the *next* hour), French `et quart`/`moins le quart`/`et
demie`, 24h-dominant disambiguation (the English "1–6 → PM" heuristic is wrong for fr/de), day-month
order, decimal comma.

**Escape hatch:** if a language is irregular beyond flags, allow one named grammar plugin for it —
defended in review, not the default.

---

## 4. How to handle translations correctly (process)

1. **Prompts/fulfillments** → professional or native human translation; reviewed as UI copy (tone,
   formality, length). Machine translation only as a first draft, always human-reviewed.
2. **Synonyms** → native-speaker sourced "how people actually say it," ideally mined from real usage
   logs in that language. **Not** API translations of the English synonyms.
3. **Canonical values & all identifiers** (intent/slot/action/context names, enum keys) → **never
   translated.**
4. **Date lexicon + grammar flags** → authored/validated by a native speaker or linguist, then **proven
   by golden fixtures**, not eyeballed.
5. **Fallback:** any missing string ID or missing language pack → fall back to `en` + `os.log` warning.
   Never render a raw key, never crash (matches the existing graceful-degradation rule).
6. **Round-trip validation:** for each language, a held-out set of real utterances → assert parsed
   intent + slot ISO + chosen prompt_id match the server reference (see §7).

---

## 5. File-by-file change map (no `if language` in engine/services)

| File | Change |
|---|---|
| `NLUSchema.swift` | Split into `NLUSchema` (structure) + `NLULocalizedStrings`; `loadFromBundle(language:)` loads structure + matching string pack; prompts resolved by ID with `en` fallback |
| `NLUEngine.swift` | Inject `strings` + `language`; read `uncertain`/`noIdioms`/`carrierPatterns`/`affirmative`/`negative` from `strings`; **orchestration body unchanged** |
| `EntityExtractor.swift` | `init(language:)`; load `enums.<lang>.json`; refactor date engine to consume `DateTimeLexicon` (tokens + grammar flags) instead of hardcoded English |
| *(new)* `DateTimeLexicon.swift` | Typed model of `lexicon.<lang>.json` |
| `NLUEngineFactoryProvider.swift` | Factories take `language`; load the right packs; still the only place naming concrete types |
| `LiveTranscriptionViewModel.swift` | Pass `coordinator.currentLocale` → factory; on `switchLocale`, reconfigure packs (JSON only, no model reload) so prompts follow language |
| **IntentClassifier repo** | Author the 4 artifact families; refactor `entities.py` to the same lexicon+flags engine; add `--emit-fixtures` per language |
| `STTTests` | Extend parity test from `(utterance)` to `(utterance, language)`; assert intent + slot ISO + prompt_id |

---

## 6. Parity & calibration (the correctness backbone)

1. **Single source of truth = server.** All four artifact families authored in IntentClassifier, vendored
   to clients. Clients never edit rules locally (same as model weights).
2. **Per-language golden fixtures.** Extend `coreml_golden_fixtures.json` from intent-only to full-NLU:
   `(utterance, language) → {expected_intent, expected_top1_conf, expected_slots_iso, expected_prompt_id}`.
   Generated by the Python reference, consumed by Swift XCTest **and** Android instrumentation.
3. **Calibration per language.** The multilingual model is likely **less/differently calibrated** on
   low-resource languages:
   - validate reliability (ECE / reliability diagram) per language on held-out data;
   - allow **per-language temperature** if a single `T` diverges across languages;
   - make `confidence_threshold` (0.70) and `interrupt_threshold` (0.75) **per-language overridable**;
   - extend the existing 0.70-gate-agreement parity assertion to run per language.
4. Resolver returns locale-independent ISO so the slot **value** is identical cross-platform even when
   the surface span differs.

---

## 7. Testing strategy

- **Unit (pure, run anywhere):** lexicon loading, string-pack resolution + fallback, grammar-flag
  behavior (German `halb`, French `et quart`).
- **Parity (macOS/Xcode + Android):** per-language golden fixtures — intent, top-1 confidence within FP16
  tolerance, exact gate agreement, slot ISO equality, prompt_id equality vs server.
- **Round-trip:** French/German held-out utterances → full `NLUEngine.handle` → assert localized prompt
  surfaced + slot parsed.
- **Pseudolocalization pass:** catch any string still hardcoded in Swift.

---

## 8. Phasing (de-risked, each phase shippable)

- **Phase 0 — Decouple (English-preserving, ~1–2 days):** split structure/strings; key-based prompts;
  move English statics into the `en` pack; thread language from ASR locale. Behavior identical to today,
  fully testable. Lands the seams safely.
- **Phase 1 — Prompts + enum slots in N languages (data):** add `strings.fr/de.json` + `enums.fr/de.json`.
  French/German users get localized prompts and enum slots immediately; date parsing still English
  (documented). Visible win, low risk.
- **Phase 2 — Date grammar engine (hard):** refactor `extractDateTime` (Swift + Python) to lexicon+flags;
  author `lexicon.fr/de.json`; per-language golden fixtures; parity gate green per language.
- **Phase 3 — Calibration & gates:** per-language temperature/threshold tuning; reliability validation;
  extend gate-agreement parity test.
- **Phase 4 (long-term/optional):** ML span tagger for languages where rule grammar plateaus; Android
  consumes identical artifacts.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| Grammar drift server↔device | Single-source artifacts + per-language golden fixtures in CI; device never owns rules |
| Low-resource miscalibration | Per-language `T` + gates; ECE validation; not a global threshold |
| Bad translations / wrong synonyms | Native sourcing + human review; round-trip tests; English fallback never shows raw keys |
| Scope creep into per-language Swift types | Languages are **data**; only model variants are **types**. New language = JSON + fixtures |
| Combinatorial test cost | Fixtures generated, not hand-written; parity harness already exists |

---

## 10. Acceptance criteria (per language shipped)

- [ ] Follow-up prompts and fulfillments surface in the user's language (driven by ASR locale).
- [ ] Yes/no, uncertainty, and carrier-phrase handling work in that language.
- [ ] Enum slots (memory/recurrence/remind) extract from native phrasings.
- [ ] `sys.date-time` and `sys.number-integer` parse that language's expressions to correct ISO/int.
- [ ] Canonical values, intent/slot/action names unchanged (English keys).
- [ ] No `if language`/`if variant` branch added to `NLUEngine`/`EntityExtractor`/services.
- [ ] Per-language golden fixtures pass on iOS (and Android when wired): intent, conf within FP16 tol,
      exact gate agreement, slot ISO equality, prompt_id equality vs server.
- [ ] Missing string/lexicon degrades to English + `os.log`, never crashes, never shows raw key.
- [ ] Calibration validated (ECE) per language; gates tuned, not inherited blindly from English.

---

## 11. Open questions (resolve before Phase 2)

1. Which languages ship first, and in what priority? (Affects fixture + native-sourcing effort.)
2. Is `entities.py` / the server NLU on a reachable branch to refactor jointly? (The local IntentClassifier
   checkout currently lacks `scripts/nlu/`; the date engine source of truth must be located.)
3. Source for native synonyms — real usage logs, or native reviewers only?
4. Does the multilingual model expose a language signal we could reuse for auto-detection later, or do we
   rely solely on the ASR locale?
5. Android NLU status — does a Kotlin port of `EntityExtractor` exist yet, or is this greenfield there?
