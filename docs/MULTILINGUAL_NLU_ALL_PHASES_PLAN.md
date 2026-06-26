# Multilingual NLU — Full Implementation Plan (Phases 0–3)

**Covers:** fr · de · da (English is canonical; unchanged throughout)
**Repos:** STT `claude/beautiful-clarke-p441d4` · IntentClassifier `claude/sharp-ramanujan-p441d4`
**Data committed:** `docs/localization-drafts/nlu_{schema,entities,lexicon}.{fr,de,da}.json`
**Audit:** See `MULTILINGUAL_NLU_IOS_IMPLEMENTATION_AUDIT.md` for evidence (file:line) behind
every claim below.

---

## Architecture principles (hold across all phases)

1. **No `if language ==`** in `NLUEngine` or `EntityExtractor`. Language is data injected via the
   factory at build time.
2. **Three axes are independent:** `NLUVariant` (CoreML model) ≠ conversation language (prompts /
   grammar) ≠ entity grammar. Changing one does not require changing the others.
3. **Graceful degradation.** Any missing or undecodable language file → English fallback +
   `os_log(.error)`. Never `fatalError`.
4. **English is byte-identical to today at every phase gate.** If existing English NLU tests fail,
   the phase is not done.
5. **Server parity contract (Phase 2).** `EntityExtractor.extractDateTime` and
   `IntentClassifier/scripts/nlu/entities.py extract_datetime` must produce identical results for
   every golden fixture in the parity CSV. Phase 2 is blocked until both sides pass.

---

## Phase 0 — Decouple prompts, fulfillments, yes/no, enum slots

**Goal:** When ASR locale is fr/de/da, spoken prompts, fulfillments, yes/no, and enum synonyms
operate in that language. English behavior is byte-identical to today. Date/time parsing stays
English-only (limitation documented).

### What already works (no code change needed)
- Slot prompts: emitted from `slot.prompt` (`NLUEngine.swift:204`).
- Fulfillment messages: `cfg.fulfillment` (`NLUEngine.swift:209`).
- Yes/no sets: `Set(schema.affirmative/negative)` (`NLUEngine.swift:43–44`).
- Enum extraction: synonym table from `nlu_entities.json` (`EntityExtractor.swift:49–58`).
- TTS voice: `AVSpeechSynthesisVoice(language: locale.identifier)` (`ConversationSpeaker.swift:84`).
- Locale source: `TranscriptionCoordinator.currentLocale` already public + live.

### Step P0-1 — Bundle localized data
Create `STT/STT/Resources/Localization/` and copy the nine JSON files from
`docs/localization-drafts/`. Add to both the app target and test target (Xcode File Inspector →
Target Membership). The synchronized group note in `MULTILINGUAL_TEST_RESOURCE_WIRING.md` applies.

### Step P0-2 — `LocalizationLoader.swift` (new)

Three static methods:

**`schema(language: String) -> NLUSchema`**
- Load canonical `nlu_schema.json` (provides `entity`, `required`, `action` — structural fields).
- If `nlu_schema.<lang>.json` exists, decode it as `[String: Any]` and apply overlay strings:
  - `intents[name].fulfillment`
  - `intents[name].slots[name].prompt` (match by slot `name`)
  - `followup.prompt` / `followup.yes.fulfillment` / `followup.no.fulfillment`
  - `affirmative` array / `negative` array
- Re-encode merged dict → decode as `NLUSchema`. Canonical fills every gap overlay omits.
- On decode error or missing file: return canonical English + `os_log(.error)`.

**`entitiesURL(language: String) -> URL`**
- Return `nlu_entities.<lang>.json` URL if bundled; else the English `nlu_entities.json` URL.
- `EntityExtractor` already accepts an injected URL — no extractor change for enums.

**`lexicon(language: String) -> NLULexicon?`**
- Decode `nlu_lexicon.<lang>.json`; return a `NLULexicon` struct with Phase-0 fields only:
  `uncertain: [String]`, `noIdioms: [String]`, `carrierPhrases: [String]`.
- Date/time grammar fields are ignored until Phase 2.
- Missing/undecodable → return `nil` (caller falls back to English defaults).

### Step P0-3 — Make `NLUEngine` word-lists injectable
Replace the three hardcoded `static let` lists with instance properties:
- `uncertain` (`:106`) → `var uncertain: [String]`
- `noIdioms` (`:113`) → `var noIdioms: [String]`
- `carrierPatterns` (`:324`) → `var carrierPatterns: [String]`

Add to `init` with defaults equal to the current English literals (English path unchanged).
`yesNo()` and `deriveTopic()` continue to read these properties — no logic change.

### Step P0-4 — Thread language through the factory
- Add `makeEngine(language: String)` to the `NLUEngineFactory` protocol (default `"en"`).
- `MultilingualNLUEngineFactory.makeEngine(language:)`:
  ```swift
  let lex = LocalizationLoader.lexicon(language: language)
  return NLUEngine(
    schema:    LocalizationLoader.schema(language: language),
    classifier: MultilingualIntentClassifierService(),
    entities:  EntityExtractor(entitiesURL: LocalizationLoader.entitiesURL(language: language)),
    uncertain: lex?.uncertain ?? NLUEngine.defaultUncertain,
    noIdioms:  lex?.noIdioms  ?? NLUEngine.defaultNoIdioms,
    carriers:  lex?.carrierPhrases ?? NLUEngine.defaultCarriers
  )
  ```
- `EnglishNLUEngineFactory.makeEngine(language:)` always passes `"en"` — behavior identical today.
- Remove the `TODO(multilingual-schema)` at `NLUEngineFactoryProvider.swift:40–44`.

### Step P0-5 — ViewModel: pass language + rebuild on locale switch
- At the engine build site (`LiveTranscriptionViewModel.swift:100`):
  `factory.makeEngine(language: currentLocale.language.languageCode?.identifier ?? "en")`
- In `switchLocale` (`:152`): set `nlu = nil` so the next `attach()` rebuilds the engine in the
  new language. (TTS already follows `currentLocale` live — only the engine needs rebuild.)

### Step P0-6 — Neutral clock times (recommended, ~10 lines)
Add two regexes to the digit-time branch of `extractDateTime` so basic clock entry works for
fr/de/da without the Phase-2 grammar engine:
- `\b(\d{1,2})h(\d{2})?\b` → matches "15h30", "9h" (French/German spoken hour)
- `\b(\d{1,2})\.(\d{2})\b` → matches "15.30" (Danish/German decimal notation)

Pure addition; English `15:30` path unaffected. If skipped, document that `reminders.add`
date entry is English-only until Phase 2.

### Step P0-7 — Tests
- All existing English NLU tests pass (merge of canonical with no overlay == canonical).
- ≥1 golden fixture per language:
  - fr: `"change la mémoire voiture"` → `Cmd.MemoryChange`, `MemoryName == "Car"`
  - de: `"ja"` → affirmative; `"nein"` → negative
  - da: `"nej"` → negative; `"jo"` → affirmative
- Degradation: missing `nlu_schema.xx.json` → English fallback, no crash, `os_log(.error)` emitted.
- Merge correctness: `LocalizationLoader.schema(language:"fr")` has French prompts but identical
  structure (entity/required/action) to canonical.

### Phase 0 definition of done
- [ ] `LocalizationLoader` merges canonical + overlay; degrades on error.
- [ ] `uncertain`/`noIdioms`/`carrierPatterns` injected from lexicon (English fallback).
- [ ] `makeEngine(language:)` threaded; `TODO(multilingual-schema)` removed.
- [ ] ViewModel passes ASR language; engine rebuilds on locale switch.
- [ ] English regression tests green; ≥1 non-English golden per language green.
- [ ] `reminders.add` date: neutral-clock times added (Step P0-6) OR limitation documented.

---

## Phase 1 — Native review gate (no new code)

**Goal:** Ship the Phase-0 wiring to real users only after native speakers confirm the drafted
translations are correct and natural. Phase 1 is a process gate, not a code phase.

### Review checklist per language

**French (fr) — review items from data README:**
- "programme" vs "mémoire" for the hearing-aid memory term.
- Carrier phrase `de|d'` over-stripping: `"^rappelle[\\s-]moi\\s+(de\\s+|d')?"` — verify it
  doesn't eat the start of reminder text.
- Colloquial synonym expansion: "ouaip" affirmative, "chais pas" uncertain.

**German (de) — review items:**
- `halb drei` = 02:30 semantics confirmed (flagged as parser trap; Phase 2 will implement).
- Regional forms: `dreiviertel` (Saxony/Bavaria = :45), `viertel` alone (= :15 in some regions).
- Synonym breadth: `Gespräch`/`Sprache` for Speech memory — is this too broad?

**Danish (da) — review items:**
- `halv tre` = 02:30 semantics confirmed (same "half counts down" trap as German).
- Bare article disambiguation: "en"/"et" (the numeral 1) vs. the indefinite article.
- Particles: "jo" (strong affirmative, implies "obviously") vs. "ja" — both affirmative ✓.
  "næ" (colloquial negative) — confirm it's in use with target demographic.
- "program" vs "hukommelse" for memory.

### Gate: sign-off form
Create `docs/NATIVE_REVIEW_SIGNOFF.md` with: reviewer name, language, date, pass/fail per item,
and approval signature. Phase 2 does not start until all three languages are signed off.

---

## Phase 2 — Lexicon-driven datetime engine (Swift + Python parity)

**Goal:** `extractDateTime` and `stripDateTime` in `EntityExtractor.swift` become language-neutral,
consuming `NLULexicon` for all language-specific data. The Python counterpart
`IntentClassifier/scripts/nlu/entities.py extract_datetime` is refactored in parallel. Golden
fixture CSVs enforce parity between Swift and Python at the gate.

This is the large phase. The lexicon data is already committed and complete — this is purely a
code refactor.

### What `NLULexicon` must expose for Phase 2

Extend the `NLULexicon` Swift struct (partial in Phase 0) with full datetime fields:

```swift
struct NLULexicon: Decodable {
    // Phase 0 (already loaded)
    let uncertain: [String]
    let noIdioms: [String]
    let carrierPhrases: [String]

    // Phase 2
    struct Grammar: Decodable {
        let timeFormat: String          // "24h" or "12h"
        let decimalHourIdioms: [DecimalHourIdiom]
        let conjunction: String?        // "Uhr", "og", "et" — hour+minute joiner word
    }
    struct DecimalHourIdiom: Decodable {
        let phrase: String
        let minutes: Int?               // positive = add, negative = subtract
        let hour: Int?                  // for fixed times (midi=12, minuit=0)
    }
    let grammar: Grammar
    let weekdays: [String: [String]]            // "Monday" → ["lundi","lun"]
    let dayAnchors: [String: [String]]          // "tomorrow" → ["demain"]
    let months: [String: [String]]              // "January" → ["janvier","janv"]
    let timeOfDay: [String: TimeOfDayEntry]     // "morning" → {names:[...], hour:8}
    let numbers0to31: [String: [String]]        // "5" → ["cinq"]
    let ordinals1to31: [String: [String]]       // "1" → ["premier","1er","1ère"]
    let relativeUnits: [String: [String]]       // "minute" → ["minute","minutes","min"]
    let relativeMarkers: [String: [String]]     // "in" → ["dans","d'ici"], "at" → ["à","a"]
    struct TimeOfDayEntry: Decodable {
        let names: [String]
        let hour: Int
    }
}
```

### Step P2-1 — `LocalizationLoader.lexicon` (full)
Extend the Phase-0 partial lexicon loader to decode all fields above. Existing Phase-0 callers
are unaffected — they only read `uncertain`/`noIdioms`/`carrierPhrases`.

### Step P2-2 — Inject `NLULexicon?` into `EntityExtractor`

Change `EntityExtractor.init`:
```swift
init(entitiesURL: URL, lexicon: NLULexicon? = nil)
```

Store `lexicon` as an instance property. All `extractDateTime` / `stripDateTime` methods read
from `lexicon` when non-nil; fall back to the current English `static let` arrays when nil.
This keeps the English path byte-identical (lexicon is nil when `language == "en"`).

### Step P2-3 — Refactor `extractDateTime` to be lexicon-driven

Replace each hardcoded English structure with a lexicon lookup. Ordered by complexity:

#### 3a. Language-neutral digit times (already covered by P0-6 if done)
These parse correctly for all languages and need no lexicon:
- `\d{1,2}:\d{2}` — colon notation ("15:30") already in `extractDateTime:265`
- `\b(\d{1,2})h(\d{2})?\b` — French/German spoken hour ("15h30", "9h")
- `\b(\d{1,2})\.(\d{2})\b` — Danish/German decimal ("15.30")

#### 3b. Replace `static let weekdays` (:139) with lexicon weekday lookup
Build a flat `[String: DayOfWeek]` reverse-lookup from `lexicon.weekdays` at init time.
For each entry `"Monday": ["lundi", "lun"]`, insert `"lundi" → .monday`, `"lun" → .monday`.
English fallback: the existing static array remains when `lexicon == nil`.

Match is case-insensitive. For German, fold case before lookup (German nouns are capitalised
in writing but mixed in speech recognition output).

#### 3c. Replace `static let numberWords` (:118) with lexicon number lookup
Build `[String: Int]` reverse-lookup from `lexicon.numbers0to31` at init time.
Also build from `lexicon.ordinals1to31` for day-of-month matching.
English fallback: existing `static let wordNums` / `normaliseWordNumbers` when `lexicon == nil`.

Example lookup chains:
- `"drei"` → 3 (German number)
- `"premier"` → 1 (French ordinal)
- `"ottende"` → 8 (Danish ordinal)

#### 3d. Drop the "1–6 → PM" heuristic for 24h languages
Current heuristic at `:351`: bare hours 1–6 assume PM. This is wrong for fr/de/da where the
clock is 24h by default.

Replace with:
```swift
let use24h = lexicon?.grammar.timeFormat == "24h"
// If use24h, never apply the AM/PM heuristic — treat bare hours as-is.
// If !use24h (en), apply the current 1-6→PM heuristic unchanged.
```

#### 3e. Lexicon-driven period names (replaces `:223–232`)
Current: hardcoded English `["morning","afternoon","evening",...]` mapped to hours.
Replace with: `lexicon.timeOfDay` dictionary lookup. Build `[String: Int]` from all `names`
arrays at init time. English fallback: existing period-name logic when `lexicon == nil`.

#### 3f. Relative markers: "in N minutes", "at 15h", "on Monday"
Current: hardcoded English `"in"`, `"at"`, `"on"` markers.

Build three flat sets at init from `lexicon.relativeMarkers`:
```swift
var inMarkers: Set<String>  // ["dans","d'ici"] (fr), ["in","nach"] (de), ["om","efter"] (da)
var atMarkers: Set<String>  // ["à","a","vers"] (fr), ["um","gegen"] (de), ["klokken","kl."] (da)
var onMarkers: Set<String>  // ["le","ce"] (fr), ["am","an"] (de), ["på","om","den"] (da)
```

Relative unit matching:
```swift
var relativeUnits: [String: String]  // "minute" → canonical key
// Built from lexicon.relativeUnits: each synonym → canonical key
// e.g. ["minute","minutes","min","mn"] → "minute"
```

#### 3g. Decimal-hour idioms: halb/halv/quart/demie (the hard part)

The `grammar.decimalHourIdioms` array encodes all idioms per language.
Each idiom has either:
- `minutes: Int` (positive = add to hour, negative = subtract from next hour), or
- `hour: Int` + `minutes: Int` for fixed absolute times (midi=12:00, minuit=00:00).

**Parser trap — German/Danish `halb`/`halv`:**
```
grammar.decimalHourIdioms for de: [{"phrase":"halb","minutes":...}]
```
Wait — the de lexicon stores these differently. Let me read the logic from the notes:

- German `"halb drei"` = 02:30: "halb X" means (X-1):30. The idiom `halb` has `minutes: -30`
  and requires the FOLLOWING hour word, then `result_hour = named_hour - 1`, `result_min = 30`.
- Danish `"halv tre"` = 02:30: same semantics as German.
- French `"moins le quart"` = hour − 15 min from NEXT hour: "huit heures moins le quart" = 07:45.
  Idiom phrase `"moins le quart"` has `minutes: -15`; result = (preceding_hour):00 − 15min, so
  the FOLLOWING hour interpretation means `named_hour - 1` + (60 - 15) = `named_hour - 1`:45.

Algorithm for a following-hour idiom (minutes < 0 and no absolute `hour` key):
```
"halb drei" → extract "halb" (idiom, minutes=-30) + hour word "drei" (=3)
result: hour = 3 - 1 = 2, minute = 60 + (-30) = 30 → "02:30" ✓
"huit heures moins le quart" → extract hour "huit" (=8) + idiom "moins le quart" (minutes=-15)
result: hour = 8 - 1 = 7, minute = 60 - 15 = 45 → "07:45" ✓
```

For preceding-hour idioms (French `et quart`=+15, `et demie`=+30):
```
"quinze heures et demie" → hour "quinze" (=15) + idiom "et demie" (minutes=+30)
result: hour = 15, minute = 30 → "15:30" ✓
```

**Match order within `extractDateTime`:**
1. Fixed absolute idioms first (`midi`=12:00, `minuit`=00:00, `Mitternacht`=00:00).
2. Decimal-hour idiom phrases (case-insensitive substring scan).
3. Bare digit + conjunction word (`15 Uhr 30`, `15h30`) — already handled.
4. Named number + conjunction + named number.
5. Day anchors (today/tomorrow/etc.) — lexicon.dayAnchors lookup.
6. Weekday — lexicon.weekdays lookup.
7. Date-of-month — lexicon.ordinals1to31 + lexicon.months.
8. Relative expressions ("dans 5 minutes") — relativeMarkers + relativeUnits.
9. Period-of-day ("le matin", "am Abend").

#### 3h. German `Viertel` patterns (regional)
- `"Viertel nach X"` = X:15 (standard everywhere)
- `"Viertel vor X"` = (X-1):45 (standard everywhere)
- `"dreiviertel X"` = (X-1):45 (Saxon/Bavarian, same as Viertel vor)
- `"viertel X"` alone = (X-1):15 (Saxon/Bavarian — ambiguous elsewhere; flag for reviewer)

These are encoded in `grammar.decimalHourIdioms` for de. The match algorithm for "Viertel nach"
is a preceding idiom: `("Viertel nach", minutes=+15, position="before_hour")`.

#### 3i. Danish `kvart over/i` patterns
- `"kvart over X"` = X:15 (quarter past)
- `"kvart i X"` = (X-1):45 (quarter to)
- `"N minutter over X"` = X:N
- `"N minutter i X"` = (X-1):(60-N)

Encoded in `grammar.decimalHourIdioms` for da. Same preceding/following logic as German Viertel.

### Step P2-4 — Refactor `stripDateTime` to be lexicon-driven

Current `:398–408`: hardcoded English patterns to strip date/time preambles from reminder text.
Replace with patterns built from `lexicon.carrierPhrases` (already loaded in Phase 0 for
`NLUEngine.carrierPatterns`, but reusable here for stripping the time preamble from the
reminder body).

Also strip `lexicon.relativeMarkers["in"/"at"/"on"]` prefixes when they precede a parsed time
expression, so "demain à 15h" strips the time and leaves the topic cleanly.

### Step P2-5 — Python parity: `IntentClassifier/scripts/nlu/entities.py`

Mirror every change from Steps P2-3/P2-4 in the Python `extract_datetime` function.

Key Python changes:
- Load `nlu_lexicon.<lang>.json` from `data/localization/` at `NLUExtractor.__init__`.
- Build reverse-lookup dicts for weekdays, numbers, months, time-of-day at init.
- Replace hardcoded `WEEKDAYS`, `MONTHS`, `NUMBER_WORDS`, `PERIOD_NAMES` constants with
  lexicon-driven dicts.
- Implement the decimal-hour idiom algorithm (same semantics as Swift).
- Apply `grammar.time_format == "24h"` to disable the AM/PM heuristic.
- Add relative marker matching from `lexicon.relative_markers`.

The Python server and iOS Swift must agree byte-for-byte on every golden fixture.

### Step P2-6 — Golden fixture CSVs (parity gate)

Create `IntentClassifier/tests/datetime_parity/` with one CSV per language:

```
nlu_datetime_parity_fr.csv
nlu_datetime_parity_de.csv
nlu_datetime_parity_da.csv
```

Each row: `utterance,expected_date,expected_time,language`

**French fixtures (minimum required):**
| Utterance | Expected date | Expected time |
|---|---|---|
| demain à 15h30 | +1day | 15:30 |
| lundi matin | next Monday | 08:00 |
| le 3 juillet | July 3 (this year) | — |
| dans 5 minutes | +5min | — |
| à midi | today | 12:00 |
| vendredi soir | next Friday | 18:00 |
| dix heures et demie | today | 10:30 |
| huit heures moins le quart | today | 07:45 |

**German fixtures (minimum required):**
| Utterance | Expected date | Expected time |
|---|---|---|
| morgen um 15 Uhr 30 | +1day | 15:30 |
| Montag früh | next Monday | 08:00 |
| am 3. Juli | July 3 | — |
| in 5 Minuten | +5min | — |
| halb drei | today | 02:30 |
| halb sechs nachmittags | today | 17:30 |
| Viertel nach drei | today | 03:15 |
| Viertel vor drei | today | 02:45 |
| dreiviertel drei | today | 02:45 |

**Danish fixtures (minimum required):**
| Utterance | Expected date | Expected time |
|---|---|---|
| i morgen klokken 15:30 | +1day | 15:30 |
| mandag morgen | next Monday | 08:00 |
| den 3. juli | July 3 | — |
| om 5 minutter | +5min | — |
| halv tre | today | 02:30 |
| halv seks om aftenen | today | 17:30 |
| kvart over to | today | 02:15 |
| kvart i tre | today | 02:45 |

Phase 2 gate: **all fixtures pass on both Swift (`XCTest`) and Python (`pytest`)** before merging.

### Step P2-7 — Tests

**Regression:** All existing English golden fixtures pass without change.

**New Phase-2 tests (Swift):**
- `testExtractDateTimeMultilingual.swift` — one test per row in each parity CSV.
- Parser trap tests: `"halb drei" → 02:30` (not 03:30), `"halv tre" → 02:30`, `"moins le quart" after 8h → 07:45`.
- 24h heuristic: `"drei Uhr"` (German, bare 3) → 03:00 (not 15:00), since German is 24h and bare 3 is not remapped.
- Period-of-day: `"ce soir"` → 18:00, `"am Abend"` → 18:00, `"om aftenen"` → 18:00.

**Python:** matching `pytest` fixtures via the same CSV.

### Phase 2 definition of done
- [ ] `NLULexicon` exposes all Phase-2 datetime fields.
- [ ] `EntityExtractor.extractDateTime` is lexicon-driven; no hardcoded English language data.
- [ ] `extractDateTime` is lexicon-driven for weekdays, months, numbers, periods, relative markers.
- [ ] Decimal-hour idioms (`halb`/`halv`/`moins le quart`/`Viertel`/`kvart`) implemented correctly.
- [ ] `grammar.time_format == "24h"` disables the "1–6 → PM" heuristic for fr/de/da.
- [ ] `stripDateTime` is lexicon-driven.
- [ ] All Phase-2 golden CSV fixtures pass in Swift (XCTest).
- [ ] All Phase-2 golden CSV fixtures pass in Python (pytest).
- [ ] `reminders.add` e2e test: French user says "demain à 15h" → date slot filled with +1day 15:00.
- [ ] English regression tests remain green.
- [ ] `MULTILINGUAL_NLU_LOCALIZATION_PLAN.md` Phase 2 → done.

---

## Phase 3 — Per-language calibration

**Goal:** Tune the intent classifier's confidence threshold and softmax temperature per language
so that each language achieves equivalent precision/recall to English. Phase 3 is a model-quality
gate, not an app-behavior change from the user's perspective.

### Context
The multilingual classifier (`MultilingualIntentClassifierService`) already runs. Phase 0–2 add
the NLU stack; Phase 3 ensures the *classifier itself* is well-calibrated per language.

### Step P3-1 — Collect per-language confidence score distributions
Run the classifier against the held-out test sets for fr/de/da:
- `IntentClassifier/tests/data/test_fr.csv`, `test_de.csv`, `test_da.csv`
- Record `(utterance, true_intent, predicted_intent, confidence_score)` tuples.
- Compute ECE (Expected Calibration Error) per language. English ECE is the baseline.

### Step P3-2 — Temperature scaling per language
If ECE for a language exceeds 1.5× the English ECE, apply temperature scaling:
- Fit a scalar temperature `T` on the calibration split (held-out from training).
- Store per-language temperatures in `IntentClassifier/config/calibration.json`:
  ```json
  { "en": 1.0, "fr": 1.15, "de": 1.08, "da": 1.22 }
  ```
- `MultilingualIntentClassifierService` reads `calibration.json` and divides logits by `T`
  before softmax.

### Step P3-3 — Confidence threshold tuning
The current threshold (or default) may not be optimal per language. ASR WER is higher for
minority languages → more edge utterances → different operating point.

For each language:
- Sweep threshold in [0.3, 0.9] at 0.05 steps.
- Find the threshold that maximises F1 on the language's validation split.
- Store per-language thresholds alongside temperatures in `calibration.json`.

### Step P3-4 — Parity gate
Acceptance criterion: each language's `(precision, recall, F1)` at its calibrated threshold
must be within 5 pp of English at its threshold. If a language fails:
- Inspect the confusion matrix for systematic errors (entity-not-extracted, wrong synonym match).
- Determine if the gap is a data quality issue (fix in the localization files) or a model issue
  (requires retraining on more per-language examples).
- Document any known gap in `MULTILINGUAL_NLU_LOCALIZATION_PLAN.md §Phase3_gaps`.

### Phase 3 definition of done
- [ ] ECE computed for fr/de/da vs English baseline.
- [ ] Per-language temperature scalars in `calibration.json` (or confirmed 1.0 if not needed).
- [ ] Per-language confidence thresholds tuned and stored.
- [ ] Each language within 5 pp F1 of English, OR gap documented + root-caused.
- [ ] `MultilingualIntentClassifierService` reads `calibration.json` at init.
- [ ] `MULTILINGUAL_NLU_LOCALIZATION_PLAN.md` Phase 3 → done.

---

## Phase sequencing summary

```
Phase 0  ──► compile + test ──► Phase 1 (native review) ──► Phase 2 ──► Phase 3
  2–3 days                       1–2 weeks (reviewer)       1 week       3–5 days
```

**Blocking dependencies:**
- Phase 1 blocks Phase 2 (don't refactor the date engine against unreviewed lexicon data;
  the `halb`/`halv`/`moins le quart` parser implementations depend on the reviewed semantics).
- Phase 2 requires parity CSV sign-off from both Swift and Python before merge.
- Phase 3 requires Phase 2 complete (calibration only makes sense once the NLU stack is correct).

**Non-blocking parallels:**
- Phase 3 test-set collection (Step P3-1) can start once Phase 0 ships.
- Python `entities.py` refactor (Step P2-5) can be authored alongside Phase 0; just not merged
  until Phase 2 gate.

---

## Quick-reference: lexicon fields used per phase

| Lexicon field | Phase 0 | Phase 2 |
|---|---|---|
| `uncertain` | ✓ (NLUEngine) | — |
| `carrier_phrases` | ✓ (NLUEngine + stripDateTime) | — |
| `affirmative` / `negative` | ✓ (schema overlay) | — |
| `grammar.time_format` | — | ✓ (AM/PM heuristic gate) |
| `grammar.decimal_hour_idioms` | — | ✓ (halb/quart/demie) |
| `grammar.conjunction` | — | ✓ (Uhr/og joiner) |
| `weekdays` | — | ✓ |
| `day_anchors` | — | ✓ |
| `months` | — | ✓ |
| `time_of_day` | — | ✓ |
| `numbers_0_to_31` | — | ✓ |
| `ordinals_1_to_31` | — | ✓ |
| `relative_units` | — | ✓ |
| `relative_markers` | — | ✓ |
