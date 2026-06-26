# Routine: Wire Multilingual NLU into iOS App (Phase 0)

> This routine is **audited and corrected** against the real code. See
> `docs/MULTILINGUAL_NLU_IOS_IMPLEMENTATION_AUDIT.md` for the evidence (file:line) behind every
> instruction here. Read that audit first — it explains *why* this is a merge-loader job, not a
> file-swap, and where the English assumptions actually live.

## Read these first

1. **`docs/MULTILINGUAL_NLU_IOS_IMPLEMENTATION_AUDIT.md`** — the verdict, the three corrections, and
   the step-by-step plan with cited evidence. This routine implements its §4.
2. **`docs/MULTILINGUAL_NLU_LOCALIZATION_PLAN.md`** — §2 (three axes; no `if language ==`), §3
   (structure vs strings — why the overlay is a patch), §8 (phasing).
3. **`STT/STT/Services/NLU/NLUEngine.swift`** — note the schema-driven prompts/fulfillments (lines
   204, 209) AND the three hardcoded English lists (`uncertain` 106, `noIdioms` 113, `carrierPatterns`
   324) that the schema does NOT cover.
4. **`STT/STT/Services/NLU/EntityExtractor.swift`** — enum extraction is data-driven (28, 49–58);
   `extractDateTime` (159–322) is English-only (Phase 2).
5. **`STT/STT/Services/NLU/NLUSchema.swift`** — `SlotDef` requires `entity`+`required`, which the
   overlay omits → the overlay cannot be decoded as a schema (this is why you need a merge loader).

---

## Goal

When the ASR locale is fr/de/da, the assistant prompts, confirms, fulfills, and matches enum slots in
that language — with the correct TTS voice — while **English behavior is byte-identical to today**.
Date/time parsing stays Phase 2 (see the optional neutral-clock step below).

Data is already committed on this branch: `docs/localization-drafts/nlu_{schema,entities,lexicon}.{fr,de,da}.json`.

---

## Critical correctness rules (do not violate)

1. **The overlay is a strings patch, NOT a schema.** `nlu_schema.<lang>.json` carries only
   `intents[].fulfillment`, `intents[].slots[].prompt`, followup texts, and `affirmative`/`negative`.
   It is missing `entity`/`required`/`action`. You MUST load the canonical `nlu_schema.json` for
   structure and **merge** the localized strings onto it. Never decode the overlay as `NLUSchema`.
2. **Localize the three engine word-lists.** `uncertain`, `noIdioms`, `carrierPatterns` are hardcoded
   English in `NLUEngine`. Move them to instance data seeded from `nlu_lexicon.<lang>.json`
   (`uncertain`, `no_idioms`, `carrier_phrases`), English as fallback. The schema overlay does NOT
   contain these.
3. **No `if language ==` branches** in `NLUEngine`/`EntityExtractor`. Language is data via the factory.
4. **Graceful degradation.** Missing/undecodable language file ⇒ fall back to English with
   `os_log(.error)`. Never `fatalError` on a missing language.
5. **Do not touch** `extractDateTime` grammar (Phase 2), `keyword_triggers`/`back_reference` regexes,
   `NLUVariant`, or the Core ML model loading.

---

## Steps (each independently compilable/testable)

### 1. Bundle the data
Create `STT/STT/Resources/Localization/` and copy `nlu_{schema,entities,lexicon}.{fr,de,da}.json`
from `docs/localization-drafts/`. Add to app + test target membership (Xcode File Inspector; see
`MULTILINGUAL_TEST_RESOURCE_WIRING.md` for the Xcode-16 synchronized-group step).

### 2. `LocalizationLoader.swift` (new) — the merge loader
- `static func schema(language: String) -> NLUSchema`
  - Load canonical `nlu_schema.json` (structure).
  - If `nlu_schema.<lang>.json` exists, overlay its strings: each `intents[name].fulfillment`,
    each `intents[name].slots[].prompt` (match by slot `name`), `followup.prompt` /
    `followup.yes.fulfillment` / `followup.no.fulfillment`, and the `affirmative`/`negative` arrays.
  - Overlay wins where present; canonical English fills every gap. Decode error/missing ⇒ canonical + log.
  - Implementation tip: decode canonical to a mutable intermediate (or JSON dict), apply the overlay
    dict, then decode into `NLUSchema`. Keep `entity`/`required`/`action` from canonical untouched.
- `static func entitiesURL(language: String) -> URL`
  - Return `nlu_entities.<lang>.json` URL if bundled, else the English URL. (`EntityExtractor` already
    takes an injected URL — no extractor change for enums.)
- `static func lexicon(language: String) -> NLULexicon?`
  - Decode the Phase-0 fields only: `uncertain`, `no_idioms`, `negative` idioms, `carrier_phrases`.
    (Date/time grammar fields are ignored until Phase 2.)

### 3. Make `NLUEngine` word-lists injectable
- Replace the three `static let` lists (lines 106/113/324) with instance properties.
- Add them to `init` with defaults equal to the current English literals, so the English path is
  unchanged. `yesNo()` and `deriveTopic()` read the instance properties — no logic change.

### 4. Thread `language` through the factory
- `NLUEngineFactory.makeEngine(language: String)` (protocol; default `"en"`).
- `MultilingualNLUEngineFactory.makeEngine(language:)`:
  ```swift
  NLUEngine(
    schema: LocalizationLoader.schema(language: language),
    classifier: MultilingualIntentClassifierService(),
    entities: EntityExtractor(entitiesURL: LocalizationLoader.entitiesURL(language: language)),
    uncertain: LocalizationLoader.lexicon(language: language)?.uncertain,
    noIdioms:  LocalizationLoader.lexicon(language: language)?.noIdioms,
    carriers:  LocalizationLoader.lexicon(language: language)?.carrierPhrases
  )
  ```
  `EnglishNLUEngineFactory.makeEngine(language:)` passes `"en"` (canonical paths). Remove the
  `TODO(multilingual-schema)` once done.

### 5. ViewModel: pass language + rebuild on locale switch
- At the build site (`LiveTranscriptionViewModel.swift:100`):
  `factory.makeEngine(language: currentLocale.language.languageCode?.identifier ?? "en")`.
- In `switchLocale` (`:152`), set `nlu = nil` after the locale changes so the next `attach()` rebuilds
  the engine in the new language. (TTS already follows `currentLocale` live via `speak(_,locale:)`.)

### 6. (Recommended) Language-neutral clock times
Add `\b(\d{1,2})h(\d{2})?\b` and `\b(\d{1,2})\.(\d{2})\b` to the digit-time branch of
`extractDateTime` so "15h30"/"15.30" fill the date slot in fr/de/da without the Phase-2 grammar
engine. Pure addition; English paths unaffected. If you skip this, document that `reminders.add`
date entry stays English-only until Phase 2.

### 7. Tests
- All existing English NLU tests pass (en merge == canonical).
- ≥1 golden fixture per language: e.g. fr `"change la mémoire voiture"` → `Cmd.MemoryChange`,
  `MemoryName == "Car"`; de `"ja"` affirmative; da `"nej"` negative.
- Missing `nlu_schema.xx.json` ⇒ English fallback, no crash, warning logged.
- `LocalizationLoader.schema(language:"fr")` has French prompts but identical structure to canonical.

---

## Definition of done

- [ ] `LocalizationLoader` merges canonical structure + localized strings; degrades to English on error.
- [ ] `uncertain`/`noIdioms`/`carrierPatterns` are injected from the lexicon (English fallback).
- [ ] `makeEngine(language:)` threads language; `TODO(multilingual-schema)` removed.
- [ ] ViewModel passes the ASR language and rebuilds the engine on locale switch.
- [ ] Enum slots, prompts, fulfillments, yes/no, and TTS voice are localized for fr/de/da.
- [ ] English regression tests green; ≥1 non-English golden fixture per language green.
- [ ] `reminders.add` date entry: either neutral-clock times added (Step 6) or limitation documented.
- [ ] Update `MULTILINGUAL_NLU_LOCALIZATION_PLAN.md` Phase 0 → done; note lexicon is partly Phase 0.

---

## Constraints
- Branch: `claude/beautiful-clarke-p441d4`. Commit per logical unit (loader, engine, factory, VM, tests).
- Do not edit the canonical `nlu_schema.json` / `nlu_entities.json`. Overlay/merge only.
- Do not add language cases to `NLUVariant`. Variant ≠ language.
