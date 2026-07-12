#!/usr/bin/env python3
"""Validate NLU model resources — the only check runnable without Xcode/macOS.

Checks:
  1. Every resource JSON file parses (schemas, lexicons, entities, weights, manifests).
  2. Each language pack in VoiceIntentKit has a manifest.json plus, for non-en packs,
     the schema/entities/lexicon overlay files LocalizationLoader expects.
  3. Resources duplicated between the app (STT/STT/Resources) and VoiceIntentKit are
     byte-identical (duplication is by design pending Phase-2 migration); drift is
     reported as a WARNING, not a failure, since mid-migration divergence can be
     intentional.

Exit code 0 = all hard checks passed (warnings allowed), 1 = a hard check failed.
"""

from __future__ import annotations

import filecmp
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

JSON_ROOTS = [
    REPO / "STT/STT/Resources",
    REPO / "VoiceIntentKit/Sources/VoiceIntentKit/Resources",
    REPO / "docs/localization-drafts",
]

PACKS_DIR = REPO / "VoiceIntentKit/Sources/VoiceIntentKit/Resources/LanguagePacks"

# App-side path → VoiceIntentKit-side path for resources that must stay in sync.
MIRRORS = [
    ("STT/STT/Resources/intent_classifier_weights.json",
     "VoiceIntentKit/Sources/VoiceIntentKit/Resources/intent_classifier_weights.json"),
    ("STT/STT/Resources/Multilingual/multilingual_intent_classifier_weights.json",
     "VoiceIntentKit/Sources/VoiceIntentKit/Resources/multilingual_intent_classifier_weights.json"),
    ("STT/STT/Resources/Multilingual/multilingual_intent_labels.json",
     "VoiceIntentKit/Sources/VoiceIntentKit/Resources/multilingual_intent_labels.json"),
    ("STT/STT/Resources/semantic_head.json",
     "VoiceIntentKit/Sources/VoiceIntentKit/Resources/semantic_head.json"),
    ("STT/STT/Resources/nlu_schema.json",
     "VoiceIntentKit/Sources/VoiceIntentKit/Resources/nlu_schema.json"),
    ("STT/STT/Resources/nlu_entities.json",
     "VoiceIntentKit/Sources/VoiceIntentKit/Resources/nlu_entities.json"),
    ("STT/STT/Resources/minilm-vocab.txt",
     "VoiceIntentKit/Sources/VoiceIntentKit/Resources/minilm-vocab.txt"),
]

OVERLAY_STEMS = ("nlu_schema", "nlu_entities", "nlu_lexicon")


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []
    checked = 0

    # 1. All JSON parses.
    for root in JSON_ROOTS:
        if not root.is_dir():
            errors.append(f"missing resource root: {root.relative_to(REPO)}")
            continue
        for path in sorted(root.rglob("*.json")):
            checked += 1
            try:
                json.loads(path.read_text(encoding="utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                errors.append(f"invalid JSON: {path.relative_to(REPO)}: {exc}")

    # 2. Language-pack completeness.
    if PACKS_DIR.is_dir():
        for pack in sorted(p for p in PACKS_DIR.iterdir() if p.is_dir()):
            code = pack.name
            if not (pack / "manifest.json").is_file():
                errors.append(f"language pack '{code}' missing manifest.json")
            if code == "en":  # base language ships in the root resources
                continue
            for stem in OVERLAY_STEMS:
                if not (pack / f"{stem}.{code}.json").is_file():
                    errors.append(f"language pack '{code}' missing {stem}.{code}.json")
    else:
        errors.append(f"missing language packs dir: {PACKS_DIR.relative_to(REPO)}")

    # 3. App ↔ VoiceIntentKit mirror drift (warning only).
    for app_rel, kit_rel in MIRRORS:
        app_path, kit_path = REPO / app_rel, REPO / kit_rel
        if not app_path.is_file() or not kit_path.is_file():
            warnings.append(f"mirror pair incomplete: {app_rel} <-> {kit_rel}")
        elif not filecmp.cmp(app_path, kit_path, shallow=False):
            warnings.append(f"mirror drift (may be intentional mid-migration): {app_rel} != {kit_rel}")

    for warning in warnings:
        print(f"WARNING: {warning}")
    for error in errors:
        print(f"ERROR: {error}")
    print(f"validate_resources: {checked} JSON files checked, "
          f"{len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
