# Multilingual NLU — iOS Implementation Audit & Depth Plan

**Author role:** Principal AI/ML engineer (on-device NLU) + iOS/CoreML.
**Purpose:** Evaluate whether the existing plan (`MULTILINGUAL_NLU_LOCALIZATION_PLAN.md`) and the
drafted data are *correct and implementable as-is*, then give a sequenced, evidence-backed plan for
the iOS side. Every claim below is verified against the actual code (file:line cited).
**Branches:** STT `claude/coreml-temperature-ios` · IntentClassifier `claude/coreml-export`.

---

## TL;DR verdict

**The architecture is ready and the design is sound — but the prior plan/routine has TWO concrete
inaccuracies that would break a naive implementation, plus one large known hole.** Fix these three
and Phase 0 is a safe, ~2–3 day change:

1. **The drafted `nlu_schema.<lang>.json` is a *strings overlay*, not a loadable schema.** It cannot
   be deserialized by the current `NLUSchema` Decodable (which requires `entity` + `required` per
   slot). It must be applied by a **merge loader**, not a file swap. *(Validates §3 of the plan.)*
2. **Three English word-lists are hardcoded *inside `NLUEngine`*, not in the schema** —
   `uncertain`, `noIdioms`, `carrierPatterns`. Swapping the schema alone leaves yes/no-uncertainty
   and topic-stripping English. These live in the drafted `nlu_lexicon.<lang>.json`, so Phase 0 must
   wire the **non-date portion of the lexicon** too — it is not a date-only file.
3. **Date/time parsing is 100% English** (`EntityExtractor.extractDateTime`). Until the Phase-2
   engine refactor, the flagship `reminders.add` **date slot will not fill** for fr/de/da and the
   user hits the 3-attempt fallback. This must be mitigated or loudly scoped, not glossed over.

Everything else the plan assumed checks out (locale source, TTS voice, DI seams).

---

## 1. What is already correct and ready (verified)

| Capability | Mechanism today | Localizes by | Evidence |
|---|---|---|---|
| Slot prompts | Emitted from `slot.prompt` | swapping/merging schema | `NLUEngine.swift:204` |
| Fulfillment messages | `cfg.fulfillment` | swapping/merging schema | `NLUEngine.swift:209,256` |
| Yes/No detection | `Set(schema.affirmative/negative)` | schema overlay (drafted ✓) | `NLUEngine.swift:43–44,122–123` |
| Enum slot extraction | synonym table from `nlu_entities.json` | swapping entities file (drafted ✓) | `EntityExtractor.swift:28,49–58,83–92` |
| Open-topic free text | raw answer fallback for `open` entities | language-neutral | `NLUEngine.swift:170–172` |
| **TTS voice** | `AVSpeechSynthesisVoice(language: locale.identifier)` | already locale-parameterized ✓ | `ConversationSpeaker.swift:69,84` |
| **Locale source** | `TranscriptionCoordinator.currentLocale` (ASR/user) | already public & live ✓ | `TranscriptionCoordinator.swift:26,369–377` |
| TTS uses live locale | `speaker.speak(text, locale: currentLocale)` | already wired ✓ | `LiveTranscriptionViewModel.swift:362` |
| DI seam for language | `factory.makeEngine()` is the only build site | one signature change | `NLUEngineFactoryProvider.swift:29,45`; `LiveTranscriptionViewModel.swift:100` |

The author already left a `TODO(multilingual-schema)` at the exact gap
(`NLUEngineFactoryProvider.swift:40–44`): "the engine still loads the English nlu_schema.json /
nlu_entities.json by default." So the design intent matches this plan.

**Conclusion:** prompts, fulfillments, yes/no, enum synonyms, and spoken voice are all already
parameterized or data-driven. The work is *wiring language through one seam and supplying the data*,
not re-architecting.

---

## 2. The three corrections (with evidence)

### 2.1 The schema overlay is not a drop-in schema — it needs a merge loader

`NLUSchema.SlotDef` requires four non-optional fields:
```swift
public struct SlotDef: Decodable, Sendable {
    public let name: String
    public let entity: String      // ← overlay omits this
    public let required: Bool      // ← overlay omits this
    public let prompt: String
}
```
(`NLUSchema.swift:11–16`)

The drafted overlay slot is only `{"name": "...", "prompt": "..."}`. Decoding it as `NLUSchema`
throws (`keyNotFound: entity`). **The overlay is a translation patch keyed by intent → slot → string;
it carries no structure.** This is exactly the structure/strings split the plan argues for in §3 —
so the data is *right*, but the loader must:

1. Load the canonical **structural** schema (`nlu_schema.json`, which has `entity`/`required`/
   `action`/`followup`).
2. Load the localized **strings overlay** (`nlu_schema.<lang>.json`).
3. Produce a merged `NLUSchema` where each `slot.prompt`, `intent.fulfillment`, and the
   `affirmative`/`negative` arrays come from the overlay when present, else the canonical English.

> Do **not** "just translate `nlu_schema.json` in place" — that re-couples structure and strings and
> means re-translating the whole structural file on every schema change. The merge loader is the
> correct, low-drift design.

### 2.2 Three English lists live in `NLUEngine`, not the schema

```swift
private static let uncertain = ["not sure","maybe","dunno","don't know", ...]   // :106
private static let noIdioms  = ["no worries","no problem", ...]                  // :113
private static let carrierPatterns = [ #"^\s*please\s+"#, ... ]                  // :324
```
These are consumed by `yesNo()` (`:120–121`) and `deriveTopic()` (`:345`). The schema overlay does
**not** carry them; the drafted **`nlu_lexicon.<lang>.json` does** (`uncertain`, `no_idioms`,
`carrier_phrases`). So Phase 0 must:

- Move these three from `static let` constants to **instance data injected from the lexicon**
  (non-date portion), with English as the fallback.
- This means `nlu_lexicon.<lang>.json` is partially consumed in Phase 0 (the yes/no + carrier parts),
  even though its **date/time grammar** stays unused until Phase 2. Update the plan's framing: the
  lexicon is not exclusively a Phase-2 artifact.

### 2.3 Date/time parsing is English-only — the `reminders.add` hole

`EntityExtractor.extractDateTime` (`:159–322`) is entirely English: weekday list (`:139`), number
words (`:118,365`), period names (`:223–232`), and every regex (`in N minutes`, `tomorrow`,
`half past`, `am/pm`). The "1–6 → PM" heuristic (`:351`) is *actively wrong* for 24h-default
languages (fr/de/da). Consequences for a French user in Phase 0:

- "demain à 15h" → no match → slot stays empty → after 3 attempts (`NLUEngine.swift:184–193`) the
  flow drops to GenAI fallback. **The reminder is effectively unusable in non-English.**
- *Partially* language-neutral paths that DO survive: 24h colon times like "15:30" (`:265`) and bare
  digits. But "15h30" (the natural French form) does **not** match (`h`, not `:`).

**Mitigation options for Phase 0 (pick one, document it):**
- **(A) Scope it out:** localize prompts/fulfillments/yes-no/enums everywhere, but keep `reminders.add`
  on English date entry only, and say so in release notes. Lowest risk.
- **(B) Minimal neutral times:** add `\d{1,2}h(\d{2})?` and `\d{1,2}\.\d{2}` to the digit-time
  regexes so "15h30"/"15.30" parse language-agnostically. ~10 lines, no grammar engine. Buys basic
  clock entry in fr/de/da without the full Phase-2 refactor. **Recommended.**
- **(C) Full Phase 2 now:** lexicon-driven engine + golden fixtures. Correct but large; not Phase 0.

---

## 3. Is the drafted data correct for iOS? Mostly — with two notes

- **Intent-count divergence (non-blocking):** the iOS bundle ships a **3-intent** schema
  (`reminders.add`, `Cmd.MemoryChange`, `Cmd.SendMessage` — `STT/STT/Resources/nlu_schema.json`),
  while the overlays carry **59** (built against the IntentClassifier server schema). The 56 extra
  intents are handled by the classifier returning an action with an **empty** spoken message
  (`NLUEngine.swift:231–233`). So on iOS today, only those 3 intents' strings are actually spoken.
  The 59-intent overlay is harmless for a merge (extras ignored) and future-proofs the app if it
  later adopts the full schema to speak all fulfillments. **No action needed for Phase 0**, but note
  it so nobody expects "Volume increased." to be spoken in French yet.
- **`Cmd.SendMessage` followup prompt** is localized in the overlay (`Tu veux envoyer ce message?`)
  and consumed via `FollowupDef.prompt` (`NLUSchema.swift:25–31`, `NLUEngine.swift:96–97,239`). Good —
  the merge loader must patch `followup.prompt` / `followup.yes.fulfillment` / `followup.no.fulfillment`
  too, not only top-level `fulfillment`.

---

## 4. Depth implementation plan (Phase 0, iOS)

Ordered, each step independently compilable/testable. No `if language ==` in engine/extractor —
language is data injected via the factory (plan §2).

### Step 1 — Bundle the localized data
- New group `STT/STT/Resources/Localization/` containing `nlu_schema.{fr,de,da}.json`,
  `nlu_entities.{fr,de,da}.json`, `nlu_lexicon.{fr,de,da}.json` (copy from
  `docs/localization-drafts/`). Add to app target (and test target) membership — see
  `MULTILINGUAL_TEST_RESOURCE_WIRING.md` for the Xcode-16 synchronized-group caveat.

### Step 2 — `LocalizationLoader` (new) + merge loader
- `LocalizationLoader.schema(language:) -> NLUSchema`: load canonical `nlu_schema.json`, then if a
  `nlu_schema.<lang>.json` overlay exists, **merge strings** (prompts, fulfillments, followup texts,
  affirmative/negative) onto the canonical structure. Decode failure or missing file ⇒ return
  canonical English + `os_log(.error)`. Never `fatalError` on a missing language.
- `LocalizationLoader.entitiesURL(language:) -> URL`: return the `nlu_entities.<lang>.json` URL when
  present, else the English URL. (`EntityExtractor` already accepts an injected URL —
  `EntityExtractor.swift:28` — so no extractor structural change for enums.)
- `LocalizationLoader.lexicon(language:) -> Lexicon?`: decode `nlu_lexicon.<lang>.json` for the
  **non-date** fields used in Phase 0: `uncertain`, `no_idioms`/`negative` idioms, `carrier_phrases`.

### Step 3 — Make `NLUEngine` language word-lists injectable
- Replace the three `static let` lists (`uncertain` `:106`, `noIdioms` `:113`, `carrierPatterns`
  `:324`) with instance properties seeded from the lexicon (fallback to the current English literals).
- No logic change in `yesNo()`/`deriveTopic()` — they just read instance data.

### Step 4 — Thread `language` through the factory → engine
- `NLUEngineFactory.makeEngine(language:)` (default `"en"`); remove the `TODO(multilingual-schema)`.
- `MultilingualNLUEngineFactory.makeEngine(language:)` builds:
  ```swift
  NLUEngine(
    schema: LocalizationLoader.schema(language: language),
    classifier: MultilingualIntentClassifierService(),
    entities: EntityExtractor(entitiesURL: LocalizationLoader.entitiesURL(language: language)),
    lexicon: LocalizationLoader.lexicon(language: language)
  )
  ```
  `EnglishNLUEngineFactory` passes `"en"` (canonical paths) — behavior identical to today.

### Step 5 — ViewModel passes language, rebuilds on locale change
- At build (`LiveTranscriptionViewModel.swift:100`): `factory.makeEngine(language: langTag)` where
  `langTag = currentLocale.language.languageCode?.identifier ?? "en"`.
- **Important:** the engine is built once when `nlu == nil` (`:99`). On `switchLocale` (`:152`) set
  `nlu = nil` so the next attach rebuilds with the new language. Without this, switching ASR locale
  mid-session leaves the NLU in the old language. (TTS already follows `currentLocale` live, so only
  the engine needs the rebuild.)

### Step 6 — (Recommended) language-neutral clock times
- Per §2.3 option B, add `\b(\d{1,2})h(\d{2})?\b` and `\b(\d{1,2})\.(\d{2})\b` to the digit-time
  branch of `extractDateTime` so "15h30"/"15.30" fill the date slot in fr/de/da. Pure addition,
  English unaffected. If skipped, document the `reminders.add` limitation.

### Step 7 — Tests
- **Regression:** all existing English NLU tests green (merge of `en` overlay == canonical).
- **New golden fixtures (≥1 per language):** e.g. fr `"change la mémoire voiture"` →
  `Cmd.MemoryChange`, `MemoryName == "Car"`; de `"ja"` → affirmative; da `"nej"` → negative.
- **Degradation:** missing `nlu_schema.xx.json` ⇒ English fallback, no crash, warning logged.
- **Merge correctness:** `LocalizationLoader.schema(language:"fr")` has French prompts but identical
  structure (entities/required/actions) to canonical.

---

## 5. Corrections to fold back into the existing docs

- `MULTILINGUAL_NLU_LOCALIZATION_PLAN.md` §8: note the **lexicon is partially a Phase-0 artifact**
  (yes/no-uncertainty + carrier phrases), not purely Phase 2.
- `MULTILINGUAL_NLU_PHASE0_ROUTINE.md`: add the **merge-loader requirement** (overlay ≠ schema), the
  **three hardcoded lists**, the **engine-rebuild-on-locale-switch**, and the **`reminders.add` date
  hole + option B**. *(Done in this revision of the routine.)*
- `NLUEngineFactoryProvider.swift:40–44`: the `TODO(multilingual-schema)` is the tracking marker;
  Step 4 closes it.

---

## 6. Go / no-go

**GO for Phase 0**, with the three corrections above folded in. The risky/large piece (date grammar)
is correctly isolated to Phase 2; everything Phase 0 touches is either already parameterized or a
mechanical data-injection through one factory seam. Recommend shipping Step 6 (neutral clock times)
with Phase 0 so `reminders.add` is not visibly broken in the localized languages.
