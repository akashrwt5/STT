# Routine: Wire Multilingual NLU into iOS App (Phase 0)

## Read these first

Before making any changes, read these four documents in full:

1. **`docs/MULTILINGUAL_NLU_LOCALIZATION_PLAN.md`** — the canonical design. The sections you must
   understand before touching code:
   - **§2 (Three axes)** — model variant ≠ conversation language ≠ entity grammar. Never add
     `.french`/`.german` cases to `NLUVariant`. Language comes from `TranscriptionCoordinator.currentLocale`,
     not the model picker.
   - **§3 (Artifact design)** — how `structure.json` + `strings.<lang>` + `enums.<lang>` + `lexicon.<lang>`
     split. The drafted JSON files map directly onto this: `nlu_schema.<lang>.json` = strings overlay,
     `nlu_entities.<lang>.json` = enums, `nlu_lexicon.<lang>.json` = lexicon (Phase 2, not now).
   - **§5 (File-by-file change map)** — which files change, which stay the same, and the DI rule:
     no `if language ==` inside `NLUEngine` or `EntityExtractor`; language is data injected via factory.
   - **§8 Phase 0 scope** — exactly what is in and out of scope for this routine.

2. **`docs/MULTILINGUAL_NLU_IMPLEMENTATION.md`** — what already shipped on this branch (Core ML
   model-variant work, `TFIDFLogisticScorer`, `MultilingualIntentClassifierService`, `NLUVariant` picker).
   Do not re-implement any of it.

3. **`STT/STT/Services/NLU/NLUEngine.swift`** — the orchestration layer (320 lines). Understand
   the slot-filling loop, how `EntityExtractor` is called, and where prompts/fulfillments are emitted.
   This is the main wiring point.

4. **`STT/STT/Services/NLU/EntityExtractor.swift`** — reads `nlu_entities.json` today. This is
   where the language-switch for enum synonyms and affirmative/negative lists lands.

---

## Context

The multilingual Core ML classifier is already wired (`NLUVariant` picker, `MultilingualIntentClassifierService`,
`NLUEngineFactoryProvider`). Switching to the multilingual model improves intent recognition in
French/German/Danish — but every other part of the conversation remains English: prompts, fulfillments,
yes/no detection, and enum slot extraction.

The localization data is drafted and committed on this branch:
- `docs/localization-drafts/nlu_schema.{fr,de,da}.json` — slot prompts + fulfillments per language
- `docs/localization-drafts/nlu_entities.{fr,de,da}.json` — enum synonyms per language

These are the files to wire in. They are localization **overlays**: same intent keys and slot names
as the canonical English `nlu_schema.json` / `nlu_entities.json`, just with localized strings.

---

## What Phase 0 achieves

After this routine, when a user is speaking French (ASR locale = `fr`):
- The NLU engine asks "Qu'est-ce que tu veux qu'on te rappelle?" instead of "What do you want to be reminded?"
- Fulfillment is spoken "Rappel créé." instead of "Reminder created."
- "oui", "d'accord", "ouais" are recognized as affirmative.
- "voiture" is extracted as the `Car` memory slot value.

English behavior is completely unchanged.

---

## Scope

**In scope:**
- Load `nlu_schema.<lang>.json` overlay and `nlu_entities.<lang>.json` by language at NLU engine init.
- Thread language (from `TranscriptionCoordinator.currentLocale`) through the stack to `NLUEngine`
  and `EntityExtractor`.
- Make slot prompts and fulfillment strings resolve from the loaded overlay (key-based, not hardcoded).
- Make enum synonym matching and affirmative/negative detection use the loaded language-specific lists.
- Graceful degradation: if a language file is missing or fails to decode, fall back to English with
  a warning log. No crash.

**Out of scope (do not touch):**
- `nlu_lexicon.<lang>.json` — date/time grammar (Phase 2; `extractDateTime` stays English-only for now).
- `keyword_triggers` and `back_reference` regexes — language-specific grammar, authored separately.
- The `NLUVariant` picker / Core ML model loading — already done in the model-variant work.
- Any `if language ==` or `switch language` branching inside `NLUEngine` or `EntityExtractor` —
  language is injected as data, not as a branch condition (see §2 and §5 of the plan doc).

---

## Files to change

### New
- `STT/STT/Services/NLU/LocalizationLoader.swift`
  - `func schema(for language: String) -> NLUSchema` — loads `nlu_schema.<lang>.json` overlay from
    bundle; merges with canonical English schema (overlay wins, canonical fills gaps); falls back to
    English on decode error with `os_log(.error, ...)`.
  - `func entities(for language: String) -> [entity-type]` — loads `nlu_entities.<lang>.json`;
    merges per-entity-key synonym lists (English synonyms already present in the file, so no manual
    merge needed); falls back to English.

- `STT/STT/Resources/Localization/` (new resource directory)
  - Copy `docs/localization-drafts/nlu_schema.{fr,de,da}.json` here.
  - Copy `docs/localization-drafts/nlu_entities.{fr,de,da}.json` here.
  - Add all six files to Xcode target membership (File Inspector, same way as the canonical JSON
    files). See `docs/MULTILINGUAL_TEST_RESOURCE_WIRING.md` for the manual Xcode step if pbxproj
    can't be hand-edited cleanly with Xcode 16 synchronized groups.

### Modified
- `STT/STT/Services/NLU/NLUSchema.swift`
  - Add `language: String` field (default `"en"`).
  - Add `func prompt(for slot: String, in intent: String) -> String` helper that returns the slot's
    prompt string (or `""` for optional slots like `recurrence`). This replaces any hardcoded string
    comparisons elsewhere.

- `STT/STT/Services/NLU/EntityExtractor.swift`
  - Change init signature: `init(entities: ..., language: String)`.
  - Load affirmative/negative/uncertain word lists from the loaded language schema (these are in
    `nlu_schema.<lang>.json` under `affirmative` / `negative`).
  - Enum synonym matching already works via the entity values — no structural change needed, just
    ensure the language-specific `nlu_entities.<lang>.json` is the one loaded.

- `STT/STT/Services/NLU/NLUEngine.swift`
  - Add `language: String` to init (passed from factory).
  - At init, call `LocalizationLoader` to load schema + entities for the language.
  - Pass loaded entities to `EntityExtractor` init.
  - Use `schema.prompt(for:in:)` instead of any hardcoded prompt strings when emitting slot prompts.
  - Use `schema.fulfillment` (from the loaded overlay) when emitting fulfillment messages.

- `STT/STT/Services/NLU/NLUEngineFactoryProvider.swift`
  - `EnglishNLUEngineFactory.makeEngine()` → `NLUEngine(classifier: IntentClassifierService(), language: "en")`
  - `MultilingualNLUEngineFactory.makeEngine()` → `NLUEngine(classifier: MultilingualIntentClassifierService(), language: language)`
    where `language` comes from `TranscriptionCoordinator.currentLocale` BCP-47 tag (e.g. `"fr"`, `"de"`, `"da"`).

- `STT/ViewModels/LiveTranscriptionViewModel.swift`
  - Pass current ASR locale language tag to `NLUEngineFactoryProvider.make(for:)` when building the
    engine. The locale is already available via `TranscriptionCoordinator`.

---

## Definition of done

- [ ] `LocalizationLoader.swift` loads and decodes the overlay JSON by language, merges with
  canonical, falls back to English on error with a warning log.
- [ ] `NLUEngine` threads `language` through from factory to `EntityExtractor`.
- [ ] Slot prompts and fulfillment messages are resolved from the loaded overlay, not hardcoded.
- [ ] Enum slot extraction uses language-specific synonyms (e.g. French "voiture" → "Car").
- [ ] Affirmative/negative detection uses the language-specific word lists.
- [ ] All existing tests pass (no English regression).
- [ ] At least one golden-fixture test: French or German enum slot extracted correctly from a
  non-English utterance (e.g. `"changement mémoire voiture"` → intent `Cmd.MemoryChange`,
  `MemoryName = "Car"`).
- [ ] Missing language file → English fallback, no crash, warning logged.
- [ ] Update `docs/MULTILINGUAL_NLU_LOCALIZATION_PLAN.md` Phase 0 status to "done" and note that
  date/time parsing remains English-only (Phase 2 pending).

---

## Constraints

- Branch: `claude/coreml-temperature-ios`
- Commit after each logical unit (loader, engine wiring, entity extractor, tests).
- No `if language ==` branching inside `NLUEngine` or `EntityExtractor`. If you find yourself writing
  that, re-read §2 and §5 of the plan doc — language is data, not a code path.
- Do not edit `nlu_schema.json` or `nlu_entities.json` (the canonical English files). Overlay only.
- Do not change `NLUVariant` or add language cases to it.
