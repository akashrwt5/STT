# Handoff prompt — VoiceIntentKit WP4

> Paste everything below the line into a new session.

---

## Role

You are a Principal iOS Engineer with hands-on ML, CoreML and on-device NLU
experience (Siri/Alexa-class intent classification).

## Read ONLY these

Do **not** go exploring the repos' other documentation. Most of it predates this
work and will send you down dead ends. Read exactly:

| File | What it is |
|---|---|
| `STT/docs/VoiceIntentKit_Architecture.md` (or `IntentClassifier/docs/Prod-Work-Documentation/`) | The ADD — the target architecture. Referred to as "the ADD". |
| `STT/docs/VIK_DATA_DRIVEN_REFACTOR_PLAN.md` | The plan. WP0–WP9. Some parts are now stale — see "Plan corrections" below. |
| `STT/VoiceIntentKit/BUG_TRACKER.md` | iOS-side defects. 8 fixed, 8 open. |
| `IntentClassifier/docs/BUG_TRACKER.md` | Compiler-side defects. 11 fixed, 13 open. |
| `STT/docs/PROMPT_FOR_NLU_COMPILER_TEAM.md` | Outstanding contract asks. |
| `STT/VoiceIntentKit/Sources/VoiceIntentKit/Data/*.swift` | The 12 files written so far. |
| `STT/VoiceIntentKit/Tests/VoiceIntentKitTests/Pack*.swift` | The parity suite. |

For anything about the Python reference, read the SOURCE
(`IntentClassifier/packages/runtime/nlu_engine/entities.py`), not docs about it.

## Where things stand

Two repos:
- `~/development/Starkey_Research/STT` — the iOS app + `VoiceIntentKit` SPM package
- `~/PycharmProjects/IntentClassifier` — the Python NLU compiler that emits packs

`VoiceIntentKit` is being converted from a package with ~29 MB of bundled
resources into one that ships **zero data** and derives everything from a
downloaded `pack-<lang>-v<version>`. The vendored fixture is
`VoiceIntentKit/Sources/pack-en-v1.0.29`.

**Done (WP1, WP3, WP5, tests):** 12 files under
`Sources/VoiceIntentKit/Data/` — pack loading with full ed25519 + sha256 trust
chain, the v3 section decoders, a pack-driven TF-IDF classifier, entity
extraction, and a datetime parser. Plus a 38-test parity suite that passes.

**In progress (WP4):** `PackEngineFactory.swift` — the seam where the pack
drives the existing `NLUEngine`. Just fixed a compile error (see "Gotchas").
Verify it builds before continuing.

## What to do next, in order

1. **Replace `EntityExtractor` inside `NLUEngine`.** This is the last thing
   holding `Bundle.module` in the package. `EntityExtractor(entitiesURL:lexicon:)`
   reads a *file* and falls back to `Bundle.module` when the URL is nil, so it
   cannot be bridged from a pack — it must be replaced by `PackEntityExtractor`
   + `PackDateTimeParser`. Six call sites in `NLUEngine`: `extract`,
   `extractDateTime`, `isOpen`, `stripDateTime` (two of them appear twice).
   `PackEngineFactory.makeEngine` currently takes the extractor as a parameter
   to keep the seam visible; collapse that once the replacement lands.
2. **`VoiceIntentSession.init` takes a pack URL and throws.** No pack ⇒ typed
   error, never a silent English fallback.
3. **Delete:** `LocalizationLoader`, `LanguagePackRegistry`, `LanguagePack`,
   `ClassifierBundle`, `NLUSchema`, `NLULexicon`, `NLUEngineFactoryProvider`,
   and `NLUEngine.defaultUncertain` / `defaultNoIdioms` / `defaultCarriers`.
4. **Strip `Resources/`** and its `resources:` block from `Package.swift` (~29 MB).
5. **Delete the obsolete tests:** `LocalizationLoaderTests`,
   `NLUEngineFactoryTests`, and the parts of `VoiceIntentSessionSmokeTests` that
   assume bundled packs.

Then WP6 (label boundary + `Cmd.*` alias), WP7 (telemetry), WP8 (OTA hot-swap).

## Decisions already made — do not relitigate

- **v3 surface only.** Every pack also ships a flattened
  `nlu_schema.json`/`nlu_entities.json`. Do not bind to it: it inlines English
  into fulfillment text, slot prompts and entity values, and drops
  `contractions`, the datetime grammar, the confirmation policy, keyword tiers
  and 9 keyword rules.
- **Strict decoding, never fall back.** A missing key throws. The predecessor
  decoded with `try? … ?? []` and silently produced English (VIK-001).
- **`.full` classifier variant is the default.** Head, vocabulary and
  temperature are ONE triple — `ClassifierVariant` binds all three or throws.
- **`computeUnits = .cpuOnly`.** Per ADR-017: `.all` costs 93.7 ms vs 15.6 ms to
  load, +1.69 MB footprint, and ANE/CPU return different logits, making the
  shipped model non-reproducible under a 0.70 gate.
- **The pack decides stage enablement**, not host configuration.
- **VoiceIntentKit never interprets an intent label.** Even out-of-scope is
  discovered from the pack.
- **One `ResolvedPack` per language.** Packs are one-per-language; switching
  language means loading a different pack, which is the same path as OTA.

## Plan corrections (the plan doc is stale here)

- **WP2 mostly does not exist.** Packs ship pre-compiled `.mlmodelc` and
  ADR-017 proved they are portable, so there is no `CoreMLCompiler`, no cache,
  no invalidation. Only a fallback for a pack shipping `.mlpackage` alone.
- **The four "orphaned" root-shim keys are resolved.** `runtime/guards.json`
  now exists; the confirm band is in `policies.thresholds`.
- **WP5's blocker is cleared.** `datetime_grammar` carries `weekdays`, `months`,
  `numbers_0_to_31`, `ordinals_1_to_31`, `clock_hour_markers`, `grammar` and
  `ordinal_context`.

## Gotchas that cost time

- **Swift type-checker timeouts.** Chained `flatMap`/`sorted`/`map` over tuple
  literals produces "unable to type-check this expression in reasonable time".
  Use plain loops with declared types and named structs, not tuples.
- **`NLUSchema` and `IntentDef` declare `init(from: Decoder)` in the type body**,
  which suppresses the synthesised memberwise init — they can only be decoded,
  never constructed. `PackEngineFactory.swift` adds explicit inits in an
  extension. Expect the same for any other legacy type you need to build.
- **`LocalizationLoaderTests.testLexiconLoadsForFrenchAndNilForUnknown` fails,
  and should.** No language file has `no_idioms`, so French/German/Danish have
  been running English idioms. It is the only visible symptom of VIK-001 and
  dies with step 3. Do not patch it.
- **The reference is the source of truth for parity.** When behaviour is in
  question, run `entities.py` and compare — do not reason from first principles.
  Six bugs were found that way this session; two of them only surfaced by
  running, after passing a careful read.
- **Regenerate fixtures, never hand-edit.**
  `Tests/VoiceIntentKitTests/Fixtures/reference_expectations.json` is captured
  from the reference at a fixed clock (`2026-08-03T10:00:00Z`, a Monday) with
  full second precision — `ISO8601DateFormatter` cannot parse minute-precision
  ISO, which cost a debugging round.

## Verification

Run the suite in Xcode (⌘U) or:

```bash
cd ~/development/Starkey_Research/STT/VoiceIntentKit
xcodebuild test -scheme VoiceIntentKit \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Expect **1 failure** (`LocalizationLoaderTests`, above) until step 3 deletes it.
Everything else must stay green.

## Working style

Verify before asserting — check the pack, the source or the reference rather
than reasoning from what a name suggests. Say plainly when something cannot be
done or when you have made a mistake. Prefer small, reviewable changes with the
reasoning in the code, and update the relevant `BUG_TRACKER.md` when a defect is
found or fixed.
