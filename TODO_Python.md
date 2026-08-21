# Python Backend Tasks (OTA Bundler)

This document tracks required updates for the Python team responsible for compiling the `.nlu` OTA zip packages for `VoiceIntentKit`.

## 1. Explicit Version Field in `bundle.json` — ✅ DONE (`bd3c5bf`, branch `feature/removeing_confirmation_code_APIVersion`)
- **Status:** `content_bundle.py::compile_manifest` now emits `"version": version` from the same
  variable that builds `bundle_id`, so the two cannot diverge. It is written before
  `build.py`'s signing stage, so it is inside the bytes the Ed25519 signature covers.
- **iOS follow-up (done):** `NLUBundle.version` / `PackIdentity.version` are now required, and the
  host-side hotfix that injected the field after extraction has been removed — it rewrote
  `bundle.json` *before* signature verification and would have failed every OTA install the day
  production signing was enabled.
- **Remaining:** the vendored iOS seed pack predates this commit (built 2026-08-08, fix 2026-08-12).
  Rebuild and re-vendor it; that also removes the hand-edited `1.0.35`.
- **Original context:** Currently, the iOS SDK relies on `bundle_id` (e.g., `"pack-en-v1.0.36"`) to name the on-disk storage directories. This tightly couples the package identifier with the storage versioning, which is an anti-pattern.
- **Action Item:** Add a dedicated `"version"` field at the root level of `bundle.json` (e.g., `"version": "1.0.36"`).
- **iOS Impact:** The `VoiceIntentKit` SDK has already been updated to parse this field (`manifest.version`) and will use it to create clean directories like `Packs/en/1.0.36/`.

## 2. Explicit Vocabulary Artifact (Optional but Recommended)
- **Context:** The iOS SDK needs to know where the vocabulary/lexicon file is located to run the NLU engine.
- **Action Item:** Add a `"vocabulary_artifact"` field to the model schema inside `bundle.json`.
- **Example:**
```json
"models": {
  "intent": {
    "en": {
      "artifact": "models/intent/en/model.onnx",
      "vocabulary_artifact": "models/intent/en/vocab.txt",
      "format": "onnx",
      "model_version": "en-1.0.36"
    }
  }
}
```
- **iOS Impact:** The SDK has already been updated to dynamically read this field to locate the vocabulary, avoiding hardcoded paths.

## 3. Pre-filter OTA Updates by SDK Compatibility
- **Context:** The Host Application currently fetches `/api/v1/nlu/latest?current_pack_version=X`. If a backend NLU package uses `format_version: "4.0"` but the iOS app only supports `3.0`, the iOS SDK will reject it *after* downloading the 30MB file.
- **Action Item:** Update the BFF `/latest` endpoint to accept an `&sdk_version=` query parameter. Use this parameter to evaluate if a compatible OTA update exists, returning `update_available: false` if the only new models require a newer SDK.
