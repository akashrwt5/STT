# Python Backend Tasks (OTA Bundler)

This document tracks required updates for the Python team responsible for compiling the `.nlu` OTA zip packages for `VoiceIntentKit`.

## 1. Explicit Version Field in `bundle.json`
- **Context:** Currently, the iOS SDK relies on `bundle_id` (e.g., `"pack-en-v1.0.36"`) to name the on-disk storage directories. This tightly couples the package identifier with the storage versioning, which is an anti-pattern.
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
