# Routine: Multilingual NLU — Full Implementation (Phases 0–3)

## Read these first

1. **`docs/MULTILINGUAL_NLU_ALL_PHASES_PLAN.md`** — the complete sequenced plan with every step
   cited (file:line where applicable). This routine implements all four phases in order.
2. **`docs/MULTILINGUAL_NLU_IOS_IMPLEMENTATION_AUDIT.md`** — Go/No-Go verdict and the three
   corrections (merge loader, injectable word-lists, `reminders.add` hole). Explains *why* each
   architectural decision was made.
3. **`docs/MULTILINGUAL_NLU_LOCALIZATION_PLAN.md`** — §2 (three axes; no `if language ==`),
   §3 (structure vs strings), §5 (datetime grammar), §8 (phasing).
4. **`STT/STT/Services/NLU/NLUEngine.swift`** — the three hardcoded English lists (`:106`, `:113`,
   `:324`) and schema-driven prompts (`:204`, `:209`).
5. **`STT/STT/Services/NLU/EntityExtractor.swift`** — `extractDateTime` (`:159–322`): English-only
   weekdays, number words, period names, and "1–6 → PM" heuristic. `static let weekdays :139`,
   `static let numberWords :118`, period names `:223–232`.
6. **`STT/STT/Services/NLU/NLUSchema.swift`** — `SlotDef` requires `entity`+`required` (`:11–16`):
   the overlay omits these → the overlay cannot be decoded as a schema (merge loader is mandatory).

---

## Goal

For fr/de/da: spoken prompts, fulfillments, yes/no, enum synonyms, and date/time are in the
user's language with the correct TTS voice. English behavior is byte-identical to today at
every phase gate.

Data is already committed on the development branches:
- STT: `docs/localization-drafts/nlu_{schema,entities,lexicon}.{fr,de,da}.json`
- IntentClassifier: `IntentClassifier/data/localization/nlu_{schema,entities,lexicon}.{fr,de,da}.json`

---

## Critical correctness rules (hold for all phases)

1. **No `if language ==`** in `NLUEngine` or `EntityExtractor`. Language is data injected via
   the factory.
2. **The overlay is a strings patch, NOT a schema.** Load canonical `nlu_schema.json` for
   structure; merge overlay strings on top. Never decode the overlay as `NLUSchema`.
3. **Three engine word-lists must come from `nlu_lexicon.<lang>.json`**, not the schema overlay:
   `uncertain`, `no_idioms`, `carrier_phrases` in `NLUEngine` (`:106`, `:113`, `:324`).
4. **Graceful degradation.** Missing/undecodable file → English fallback + `os_log(.error)`.
   Never `fatalError`.
5. **Server parity (Phase 2).** `extractDateTime` in Swift and in Python (`entities.py`) must
   agree on every row of the golden fixture CSVs before Phase 2 merges.
6. **Do not touch** `extractDateTime` grammar in Phase 0 beyond the neutral-clock regex (Step
   P0-6). Do not change `NLUVariant`, CoreML model loading, or keyword-trigger regexes in any
   phase.

---

## Phase 0 — Prompts · Yes/No · Enum slots

**Scope:** Merge loader, injectable word-lists, factory threading, ViewModel locale rebuild,
neutral-clock times. English unchanged.

### P0-1 — Bundle localized data

Create `STT/STT/Resources/Localization/`.
Copy `docs/localization-drafts/nlu_{schema,entities,lexicon}.{fr,de,da}.json` into it.
Add all nine files to both the app target and test target (Xcode File Inspector → Target
Membership). See `MULTILINGUAL_TEST_RESOURCE_WIRING.md` for the Xcode-16 synchronized-group step.

### P0-2 — `LocalizationLoader.swift` (new)

```swift
// STT/STT/Services/NLU/LocalizationLoader.swift
enum LocalizationLoader {
    static func schema(language: String) -> NLUSchema
    static func entitiesURL(language: String) -> URL
    static func lexicon(language: String) -> NLULexicon?
}
```

**`schema(language:)`**
1. Load canonical `nlu_schema.json` as `[String: Any]` JSON dict (this carries `entity`,
   `required`, `action` — structural fields the overlay omits).
2. If `nlu_schema.<lang>.json` exists, decode it as `[String: Any]` and merge strings onto the
   canonical dict by walking `intents[name].fulfillment`, `intents[name].slots[name].prompt`,
   `followup.prompt`, `followup.yes.fulfillment`, `followup.no.fulfillment`,
   `affirmative` array, `negative` array.
3. Re-encode the merged dict to `Data`; decode as `NLUSchema`.
4. On any error (missing file, JSON decode failure): return canonical English + `os_log(.error)`.

**`entitiesURL(language:)`**
Return the `nlu_entities.<lang>.json` bundle URL if present; otherwise return the English URL.

**`lexicon(language:)` (Phase-0 fields only)**
Decode `nlu_lexicon.<lang>.json` and return a `NLULexicon` with:
`uncertain: [String]`, `noIdioms: [String]`, `carrierPhrases: [String]`.
Date/time grammar fields (Phase 2) are ignored here. Missing/undecodable → return `nil`.

### P0-3 — Make `NLUEngine` word-lists injectable

Replace the three `private static let` constants:
```swift
// Before (NLUEngine.swift:106,113,324)
private static let uncertain    = ["not sure", ...]
private static let noIdioms     = ["no worries", ...]
private static let carrierPatterns = [#"^\s*please\s+"#, ...]

// After
var uncertain:       [String]       // default = English literals above
var noIdioms:        [String]
var carrierPatterns: [String]
```

Add to `NLUEngine.init` with English defaults. No logic changes — `yesNo()` and `deriveTopic()`
already read these lists, now as instance properties.

Expose the defaults as `static let` on `NLUEngine` (e.g. `NLUEngine.defaultUncertain`) so
`LocalizationLoader` can use them as fallbacks.

### P0-4 — Thread language through the factory

Add `makeEngine(language: String)` to the `NLUEngineFactory` protocol; default implementation
passes `"en"`.

`MultilingualNLUEngineFactory.makeEngine(language:)`:
```swift
let lex = LocalizationLoader.lexicon(language: language)
return NLUEngine(
  schema:    LocalizationLoader.schema(language: language),
  classifier: MultilingualIntentClassifierService(),
  entities:  EntityExtractor(entitiesURL: LocalizationLoader.entitiesURL(language: language)),
  uncertain: lex?.uncertain     ?? NLUEngine.defaultUncertain,
  noIdioms:  lex?.noIdioms      ?? NLUEngine.defaultNoIdioms,
  carriers:  lex?.carrierPhrases ?? NLUEngine.defaultCarriers
)
```

`EnglishNLUEngineFactory.makeEngine(language:)` always uses `"en"` — behavior identical today.
Remove the `TODO(multilingual-schema)` comment at `NLUEngineFactoryProvider.swift:40–44`.

### P0-5 — ViewModel: pass language + rebuild on locale switch

At `LiveTranscriptionViewModel.swift:100`:
```swift
let langTag = currentLocale.language.languageCode?.identifier ?? "en"
nlu = factory.makeEngine(language: langTag)
```

In `switchLocale` at `:152`: set `nlu = nil` before the locale changes so the next `attach()`
call rebuilds the engine in the new language. TTS already follows `currentLocale` live.

### P0-6 — Neutral clock times in `extractDateTime` (recommended)

Add two regexes to the digit-time branch of `extractDateTime` (before the Phase-2 full refactor):
```swift
// French/German "15h30", "9h"
\b(\d{1,2})h(\d{2})?\b
// Danish/German "15.30"
\b(\d{1,2})\.(\d{2})\b
```

Pure addition. English `15:30` is unaffected. If skipped, document that `reminders.add` date
entry remains English-only until Phase 2 ships.

### P0-7 — Tests

- All existing English NLU tests pass unchanged.
- Golden fixtures (≥1 per language):
  - fr: `"change la mémoire voiture"` → `Cmd.MemoryChange`, `MemoryName == "Car"`
  - de: `"ja"` → affirmative; `"nein"` → negative
  - da: `"nej"` → negative; `"jo"` → affirmative
- Degradation: missing `nlu_schema.xx.json` → English fallback, no crash, `os_log(.error)`.
- Merge check: `LocalizationLoader.schema(language:"fr")` has French prompts but identical
  `entity`/`required`/`action` to canonical.

### Phase 0 gate (all must pass before Phase 1)
- [ ] `LocalizationLoader` merges canonical + overlay; degrades gracefully.
- [ ] `uncertain`/`noIdioms`/`carrierPatterns` injected from lexicon, English fallback.
- [ ] `makeEngine(language:)` wired; `TODO(multilingual-schema)` removed.
- [ ] ViewModel passes ASR language; engine rebuilds on locale switch.
- [ ] English regression tests green; ≥1 non-English golden per language green.
- [ ] `reminders.add` date: neutral-clock times added OR limitation documented.

---

## Phase 1 — Native review gate

**This is a process gate, not a code phase.** Do not start Phase 2 until sign-off is received.

Create `docs/NATIVE_REVIEW_SIGNOFF.md`. For each language (fr, de, da), a native reviewer must
confirm or flag:

**French:** "programme" vs "mémoire" for hearing-aid memory term; carrier phrase `de|d'`
over-stripping risk; "ouaip"/"chais pas" naturalness.

**German:** `halb drei` = 02:30 semantics confirmed; `dreiviertel` regional form noted;
synonym breadth for `Gespräch`/`Sprache`.

**Danish:** `halv tre` = 02:30 confirmed; "en"/"et" article disambiguation; "jo" vs "ja" both
affirmative; "næ" in use with target demographic; "program" vs "hukommelse".

Sign-off form: reviewer name, language, date, pass/flag per item, approval signature.

**Phase 1 gate:** `NATIVE_REVIEW_SIGNOFF.md` populated and signed for all three languages.

---

## Phase 2 — Lexicon-driven DateTime engine (Swift + Python parity)

**Prerequisite:** Phase 1 sign-off received. The `halb`/`halv`/`moins le quart` parser
implementations depend on the reviewed semantics; do not implement against unreviewed data.

**Scope:** Refactor `EntityExtractor.extractDateTime` and `EntityExtractor.stripDateTime` to
consume `NLULexicon` for all language-specific data. Mirror the change in Python. Gate on
golden fixture CSVs passing on both platforms.

### P2-1 — Extend `NLULexicon` for full datetime fields

Extend the Swift `NLULexicon` struct and `LocalizationLoader.lexicon` to decode all fields
from `nlu_lexicon.<lang>.json`:

```swift
struct NLULexicon: Decodable {
    // Phase 0 (unchanged)
    let uncertain: [String]
    let noIdioms: [String]
    let carrierPhrases: [String]
    // Phase 2
    struct Grammar: Decodable {
        let timeFormat: String                  // "24h" or "12h"
        let decimalHourIdioms: [DecimalHourIdiom]
        let conjunction: String?                // hour-minute joiner ("Uhr", "og")
    }
    struct DecimalHourIdiom: Decodable {
        let phrase: String
        let minutes: Int?                       // +add or −subtract
        let hour: Int?                          // for fixed times (midi=12)
    }
    let grammar: Grammar
    let weekdays:       [String: [String]]      // "Monday" → ["lundi","lun"]
    let dayAnchors:     [String: [String]]      // "tomorrow" → ["demain"]
    let months:         [String: [String]]
    let timeOfDay:      [String: TimeOfDayEntry]
    let numbers0to31:   [String: [String]]
    let ordinals1to31:  [String: [String]]
    let relativeUnits:  [String: [String]]
    let relativeMarkers:[String: [String]]
    struct TimeOfDayEntry: Decodable {
        let names: [String]; let hour: Int
    }
}
```

### P2-2 — Inject `NLULexicon` into `EntityExtractor`

Change `EntityExtractor.init`:
```swift
init(entitiesURL: URL, lexicon: NLULexicon? = nil)
```

Build reverse-lookup tables at init (not per-call):
- `weekdayLookup: [String: DayOfWeek]` — from all `lexicon.weekdays` synonyms (lowercased).
- `numberLookup: [String: Int]` — from `lexicon.numbers0to31` + `lexicon.ordinals1to31`.
- `monthLookup: [String: Int]` — from `lexicon.months` (1=January).
- `periodLookup: [String: Int]` — from all `lexicon.timeOfDay.*.names` → `.hour`.
- `unitLookup: [String: String]` — from `lexicon.relativeUnits` synonyms → canonical key.
- `inMarkers`, `atMarkers`, `onMarkers: Set<String>` — from `lexicon.relativeMarkers`.
- `idiomMap: [(phrase: String, minutesDelta: Int?, absoluteHour: Int?)]` — from
  `lexicon.grammar.decimalHourIdioms`, sorted longest-phrase-first to avoid partial matches.

English fallback: all `extractDateTime` methods guard `guard let lex = lexicon else { ... }`
and fall through to the existing `static let` English arrays. English path byte-identical.

### P2-3 — Refactor `extractDateTime`

The priority order within `extractDateTime` when `lexicon != nil`:

1. **Digit times (language-neutral):** `\d{1,2}:\d{2}`, `\d{1,2}h\d{0,2}`, `\d{1,2}\.\d{2}`.
2. **Absolute idioms first** (`midi`, `minuit`, `Mitternacht`, `midnat`) — from `idiomMap` where
   `absoluteHour != nil`.
3. **Decimal-hour idiom scan** (case-insensitive) — from `idiomMap` where `minutes != nil`:
   - Idiom is a *following-hour* idiom if `minutes < 0`: extract the immediately-following
     number word. `result = (namedHour - 1, 60 + minutes)`.
     Example: `"halb drei"` → idiom "halb" (−30) + "drei" (3) → 02:30.
     Example: `"moins le quart"` after hour word — already consumed hour; apply same rule.
   - Idiom is a *preceding-hour* idiom if `minutes > 0`: extract the preceding or following
     number word (depends on language word order). `result = (namedHour, minutes)`.
     Example: `"quinze heures et demie"` → hour 15 + "et demie" (+30) → 15:30.
   - German `"Viertel nach X"` → X:15; `"Viertel vor X"` → (X-1):45;
     `"dreiviertel X"` → (X-1):45; `"viertel X"` → (X-1):15 (regional, flag in note).
   - Danish `"kvart over X"` → X:15; `"kvart i X"` → (X-1):45.
4. **Named number + conjunction + named number** — `lexicon.grammar.conjunction` as separator
   (`"Uhr"` for de: `"drei Uhr dreißig"` → 3:30; `"og"` for da).
5. **Day anchors** — `lexicon.dayAnchors` lookup: "aujourd'hui"→today, "morgen"→+1d, etc.
6. **Weekday names** — `weekdayLookup` case-insensitive match.
7. **Date of month** — `numberLookup`/`ordinals` + `monthLookup`.
8. **Relative expressions** — `inMarkers` + `unitLookup`: "dans 5 minutes" → +5min;
   "in 5 Minuten" → +5min; "om 5 minutter" → +5min.
9. **Period of day** — `periodLookup`: "le matin"→8h, "am Abend"→18h, "om aftenen"→18h.

**AM/PM heuristic gate (`:351`):**
```swift
if lexicon?.grammar.timeFormat == "24h" {
    // do NOT remap bare hours 1–6 to PM — 24h clock, no remapping
} else {
    // English: apply current 1-6→PM heuristic
}
```

### P2-4 — Refactor `stripDateTime`

Replace hardcoded English patterns (`:398–408`) with patterns built from:
- `lexicon.carrierPhrases` (already loaded in Phase 0; reuse here for time-preamble stripping).
- After stripping the relative/at/on marker + parsed time expression, trim remaining whitespace.
English fallback: existing patterns when `lexicon == nil`.

### P2-5 — Python parity: `entities.py extract_datetime`

In `IntentClassifier/scripts/nlu/entities.py`:
- `NLUExtractor.__init__`: load `data/localization/nlu_lexicon.<lang>.json` when `language != "en"`.
- Build the same reverse-lookup dicts (weekdays, numbers, months, time-of-day, relative) at init.
- Port the decimal-hour idiom algorithm (Steps P2-3 bullets 3–4).
- Apply `grammar.time_format == "24h"` to disable the PM heuristic.
- English path: existing code, gated on `language == "en"` or absent lexicon.

### P2-6 — Golden fixture CSVs

Create `IntentClassifier/tests/datetime_parity/` with:

`nlu_datetime_parity_fr.csv` — minimum required rows:
```
utterance,expected_date,expected_time,language
"demain à 15h30",+1d,15:30,fr
"lundi matin",next_monday,08:00,fr
"le 3 juillet",july_3,-,fr
"dans 5 minutes",+5min,-,fr
"à midi",today,12:00,fr
"vendredi soir",next_friday,18:00,fr
"dix heures et demie",today,10:30,fr
"huit heures moins le quart",today,07:45,fr
```

`nlu_datetime_parity_de.csv` — minimum required rows:
```
utterance,expected_date,expected_time,language
"morgen um 15 Uhr 30",+1d,15:30,de
"Montag früh",next_monday,08:00,de
"am 3. Juli",july_3,-,de
"in 5 Minuten",+5min,-,de
"halb drei",today,02:30,de
"halb sechs nachmittags",today,17:30,de
"Viertel nach drei",today,03:15,de
"Viertel vor drei",today,02:45,de
"dreiviertel drei",today,02:45,de
```

`nlu_datetime_parity_da.csv` — minimum required rows:
```
utterance,expected_date,expected_time,language
"i morgen klokken 15:30",+1d,15:30,da
"mandag morgen",next_monday,08:00,da
"den 3. juli",july_3,-,da
"om 5 minutter",+5min,-,da
"halv tre",today,02:30,da
"halv seks om aftenen",today,17:30,da
"kvart over to",today,02:15,da
"kvart i tre",today,02:45,da
```

### P2-7 — Tests

- All existing English NLU tests pass (English path unaffected).
- `testExtractDateTimeMultilingual.swift`: one test per fixture row per language.
- Parser trap assertions: `"halb drei" → 02:30` (not 03:30); `"halv tre" → 02:30`;
  `"huit heures moins le quart" → 07:45` (not 08:15).
- 24h heuristic: `"drei Uhr"` → 03:00 (not 15:00 — German 24h, no remapping).
- Python `pytest tests/test_datetime_parity.py` — identical pass/fail per fixture.

### Phase 2 gate (all must pass before Phase 3)
- [ ] `NLULexicon` decodes all Phase-2 datetime fields.
- [ ] `EntityExtractor.extractDateTime` is lexicon-driven for weekdays, months, numbers, periods,
  relative markers, and decimal-hour idioms.
- [ ] `halb`/`halv` correctly produce `(namedHour - 1):30`; `moins le quart` produces `(hour-1):45`.
- [ ] `grammar.time_format == "24h"` disables the AM/PM heuristic for fr/de/da.
- [ ] `stripDateTime` is lexicon-driven.
- [ ] All golden CSV fixtures pass in Swift (XCTest).
- [ ] All golden CSV fixtures pass in Python (pytest).
- [ ] e2e test: French user says `"demain à 15h"` → date slot = +1day 15:00.
- [ ] English regression tests remain green.

---

## Phase 3 — Per-language calibration

**Prerequisite:** Phase 2 merged. The classifier must be producing correct intent predictions
with correct NLU extraction before calibration is meaningful.

### P3-1 — Collect per-language score distributions

Run `MultilingualIntentClassifierService` on the held-out test sets for fr/de/da:
- `IntentClassifier/tests/data/test_{fr,de,da}.csv`
- Record `(utterance, true_intent, predicted_intent, raw_confidence)` tuples.
- Compute ECE per language. English ECE = calibration baseline.

### P3-2 — Temperature scaling

If ECE for a language exceeds 1.5× English ECE:
- Fit scalar temperature `T` on a calibration split (10% of per-language train data).
- Verify ECE decreases on the held-out split.
- Store in `IntentClassifier/config/calibration.json`:
  ```json
  { "en": 1.0, "fr": <T_fr>, "de": <T_de>, "da": <T_da> }
  ```
`MultilingualIntentClassifierService` divides logits by `T[language]` before softmax.
Default `T = 1.0` if calibration.json absent or language missing.

### P3-3 — Confidence threshold tuning

For each language, sweep threshold `t ∈ [0.3, 0.9]` at 0.05 steps on the validation split.
Select `t` that maximises macro F1. Store per-language thresholds in `calibration.json`:
```json
{
  "en": {"temperature": 1.0, "threshold": 0.65},
  "fr": {"temperature": 1.15, "threshold": 0.60},
  ...
}
```

### P3-4 — Parity gate

Each language's `(precision, recall, F1)` at its calibrated threshold must be within 5 pp of
English at its threshold. If a language fails:
- Inspect confusion matrix for systematic errors.
- Determine: data quality issue (fix localization files) or model issue (retraining needed).
- Document any gap and its root cause in `MULTILINGUAL_NLU_LOCALIZATION_PLAN.md §Phase3_gaps`.

### Phase 3 gate
- [ ] ECE computed per language; temperature scalars in `calibration.json` (or confirmed 1.0).
- [ ] Per-language thresholds tuned and stored.
- [ ] Each language within 5 pp F1 of English, OR gap documented with root cause.
- [ ] `MultilingualIntentClassifierService` reads `calibration.json` at init.
- [ ] `MULTILINGUAL_NLU_LOCALIZATION_PLAN.md` Phase 3 → done.

---

## Constraints

- **Branches:** STT `claude/beautiful-clarke-p441d4` · IntentClassifier `claude/sharp-ramanujan-p441d4`
- Commit per logical unit (loader, engine, factory, ViewModel, datetime refactor, Python parity, tests).
- Do not edit canonical `nlu_schema.json` / `nlu_entities.json`. Overlay/merge only.
- Do not add language cases to `NLUVariant`. Variant ≠ language.
- Do not push Phase 2 until the golden CSV parity gate passes on both platforms.

---

## Definition of done (all phases)

- [ ] Phase 0: Prompts/yes-no/enum localized; English unchanged.
- [ ] Phase 1: Native review sign-off for fr, de, da.
- [ ] Phase 2: `extractDateTime` lexicon-driven; `halb`/`halv`/`moins le quart` correct;
  golden CSV parity gate green on Swift + Python.
- [ ] Phase 3: Per-language calibration; all languages within 5 pp F1 of English.
- [ ] `MULTILINGUAL_NLU_LOCALIZATION_PLAN.md` all phases marked done.
