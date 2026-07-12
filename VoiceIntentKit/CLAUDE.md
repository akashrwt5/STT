# VoiceIntentKit (SPM package)

Self-contained copy of the app's STT + NLU stack packaged for reuse (single-language per
bundle, selected via `VoiceIntentConfiguration.language`). The app's own sources under
`STT/STT/` are intentionally left untouched until the Phase-2 migration — see MIGRATION.md.

Rules:
- Sources here mirror `STT/STT/`; a bug fix in one usually needs the same fix in the other.
  Say so in the commit/PR if you only patched one side.
- Resources use `Bundle.module` with flat lookups; language packs live in
  `Resources/LanguagePacks/<code>/` each with a `manifest.json` (enumerated by
  `LanguagePackRegistry`). Keep `.process` (CoreML) vs `.copy` (JSON, byte-exact parity)
  semantics in Package.swift exactly as they are.
- Tests (`swift test`, macOS only) include parity tests against
  `Tests/VoiceIntentKitTests/Resources/coreml_golden_fixtures.json` — regenerate fixtures
  from the IntentClassifier repo, never hand-edit.

INTEGRATION.md = consumer-facing how-to; NEXT_STEPS_PROMPT.md = planned follow-up work.
