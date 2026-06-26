# Wiring multilingual resources into the STTTests target

The cross-language parity test (`STTTests/IntentClassifierCoreMLParityTests.swift`)
loads its model resources from the **xctest bundle** (`Bundle(for:)`), not the
host app bundle. Models whose resources are absent from that bundle are **skipped,
not failed**, so the suite is green today — but the `multilingual` (and `en`/`fr`/
`de`/`da`/`multilingual_small`) fixtures only actually run once their resources are
members of the `STTTests` target.

## Why this is a manual Xcode step

The project uses Xcode 16 **file-system synchronized root groups**
(`PBXFileSystemSynchronizedRootGroup`). The `STT/` folder synchronizes into the
**STT app target**; `STTTests/` synchronizes into the **STTTests target**. A
synchronized group's files build for exactly one target, and the only hand-editable
override (`PBXFileSystemSynchronizedBuildFileExceptionSet`) can *remove* or
re-attribute files within that group — it cannot cleanly *add* an app-target file to
a second target. Doing this correctly (without a duplicate-membership conflict) is a
job for Xcode's project editor, so it is intentionally not hand-edited here.

## Steps (on macOS, in Xcode)

For each model you want the parity test to exercise (`multilingual`, and optionally
`en`, `fr`, `de`, `da`, `multilingual_small`):

1. Select, in the Project navigator:
   - `IntentClassifier_<model>.mlpackage`
   - `<model>_intent_classifier_weights.json`
2. In the File inspector → **Target Membership**, tick **STTTests** (leave **STT**
   ticked too).
3. Build the `STTTests` target. The previously-skipped model now runs and is checked
   against `coreml_golden_fixtures.json` (intent match, top-1 confidence within FP16
   tolerance, exact agreement on the 0.70 gate).

The multilingual artifacts already ship in the app target at
`STT/STT/Resources/Multilingual/`, so no files need to be copied — only their
test-target membership needs ticking.
