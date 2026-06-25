# Localization drafts (data only — NOT wired into the build)

**Draft data artifacts** for the multilingual NLU work (`../MULTILINGUAL_NLU_LOCALIZATION_PLAN.md`).
Kept under `docs/` (outside the synchronized `STT/` app group) so they are **not** bundled into the
app yet. Nothing here changes app behavior — wiring them in is the separate, approval-gated code work.

These files are the **mirror** of the source of truth in the IntentClassifier repo
(`IntentClassifier/data/localization/`). Keep the two copies byte-identical when either changes.

## Scope: fr · de · da

The multilingual classifier supports four languages — **en, fr, de, da**. English is canonical
(it ships as `STT/STT/Resources/nlu_entities.json` + `nlu_schema.json`); this directory holds the
**French, German, Danish** drafts. They are **machine-drafted and NOT yet native-reviewed**.

## Three file families per language

| File | What it localizes |
|------|-------------------|
| `nlu_entities.<lang>.json` | Enum synonyms (memory 38, recurrence 21, remind 6). English keys preserved; English synonyms kept + target synonyms added. |
| `nlu_schema.<lang>.json` | **Overlay** carrying only translatable strings: slot prompts, fulfillments, affirmative/negative. Brand names left untranslated. `keyword_triggers`/`back_reference` regexes are **pending** (language-specific grammar). |
| `nlu_lexicon.<lang>.json` | Date/time grammar (weekdays, months, numbers 0–31, ordinals, time-of-day, relative units), yes/no/uncertain words, and carrier-phrase regexes that strip reminder preambles. |

`nlu_entities.fr.json` was hand-corrected earlier from the product owner's synonyms (English keys
flipped back into place, missing recurrence values added); de/da entities were drafted to match its
structure and quality bar.

## ⚠️ Date-parser traps the drafts flag (honor these when the lexicon-driven parser lands)
- **German `halb drei` = 02:30**, **Danish `halv tre` = 02:30** — "half" counts DOWN to the named
  hour; a naive `X:30` reading is an hour late.
- **French `moins le quart`** subtracts from the *next* hour.

## Still needs native review (highlights)
- **fr:** "programme" vs "mémoire" for the hearing-aid memory term; carrier `de|d'` over-stripping.
- **de:** `halb drei` mapping; regional `dreiviertel`/`viertel`; broad synonyms (Speech→Gespräch/Sprache).
- **da:** `halv tre` mapping; bare article "en"/"et" vs number 1; "jo"/"næ" particles; program vs hukommelse.
- All: colloquial synonym expansion was kept conservative; numeric memory names (one/two/…) include
  very common bare words, bounded only because entity extraction is per-pending-slot.

The lexicon files cover `sys.date-time` / `sys.number-integer` (grammar/code), which the entity
files intentionally do not. See the plan's §3.4 and §5.
