# Localization drafts (data only — NOT wired into the build)

These are **draft data artifacts** for the multilingual NLU work
(`docs/MULTILINGUAL_NLU_LOCALIZATION_PLAN.md`). They are intentionally kept under `docs/`
(outside the synchronized `STT/` app group) so they are **not** bundled into the app yet.
Nothing here changes app behavior. Wiring them in is the separate, approval-gated code work.

## `nlu_entities.fr.json` — French enum entities

Built from the French synonyms provided by the product owner, corrected to the production schema:

- **English canonical keys preserved** (`"Car"`, `"Take Medication"`, …) — only the *synonym lists*
  are French. The owner's draft had the French word in the `value` field, which would break the
  slot→action mapping and server parity; that has been flipped back.
- **Full coverage:** memory 38/38, recurrence 21/21 (the missing `Biweekly`, `3 Months`, `6 Months`
  were added), remind 6/6.
- **English synonyms retained** alongside French for code-switching robustness.
- **Quality fixes applied:** `Custom One` → "première coutume"; `Pick Up Prescription` → "récupérer /
  aller chercher une ordonnance"; `Clean Hearing Aids` → "nettoyer les aides auditives"; "en plein air";
  weekday plurals ("les vendredis").

### Still needs native review
- Colloquial synonym expansion (e.g. Car → "auto"/"bagnole", Work → "boulot") — kept conservative here.
- **False-positive risk:** the numeric memory names `one/two/three/four` include bare French words
  `un`/`deux` which are extremely common tokens. They are only matched while filling the `MemoryName`
  slot of the `Cmd.MemoryChange` intent (entity extraction is per-pending-slot), which bounds the risk,
  but a native pass should confirm.

This file does **not** cover `sys.date-time` / `sys.number-integer` — those are grammar/code
(the date lexicon), not synonym data. See the plan's §3.4 and §5.
