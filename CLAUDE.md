# STT — On-Device Speech-to-Text + NLU (iOS 26+)

Offline hearing-aid companion pipeline: mic/file audio → SpeechAnalyzer STT → 3-stage intent
classifier (keyword → CoreML TF-IDF+LogReg → MiniLM semantic rescue) → intent execution.
No network at runtime. The Python repo `akashrwt5/IntentClassifier` is the source of truth
for models/schema; the iOS side must match its outputs exactly (parity fixtures).

## Repo map
- `STT/` — the app. `STT/STT/` holds Audio/, Recognition/, Coordinator/, Services/ (NLU),
  Models/, Protocols/, Extensions/; SwiftUI in Views/ + ViewModels/. Resources/ = CoreML
  packages, weights JSON, per-language NLU packs.
- `IntentKit/` — reusable NLU SPM package. `IntentKitCore` is pure Swift (unit-testable
  without models); CoreML backend is a separate target. See `IntentKit/CLAUDE.md`.
- `VoiceIntentKit/` — self-contained STT+NLU SPM package (Phase-2 migration target; app
  sources stay untouched). See `VoiceIntentKit/CLAUDE.md`.
- `STTTests/`, `STTUITests/`, `IntentKit/Tests/`, `VoiceIntentKit/Tests/` — XCTest.
- `docs/` — deep architecture + multilingual NLU plans. **`docs/project-memory/` is the
  durable cross-session memory** (architecture.md, decisions.md = ADRs, progress.md,
  risks.md). Read the relevant file before large tasks; append to decisions.md/progress.md
  after significant changes instead of re-explaining in chat.
- `.github/workflows/ios-coreml-parity.yml` — CI parity tests on macOS runners.

## Environment constraints (important)
- Building/testing Swift requires **macOS + Xcode 26** (iOS 26 SDK). Claude Code web/cloud
  sessions run on Linux with **no Swift toolchain** — never attempt `xcodebuild`/`swift`
  there; rely on CI or the user's Mac for compile/test verification, and say so explicitly.
- On Linux the only runnable check is `python3 scripts/validate_resources.py` (JSON model
  resource integrity + language-pack consistency). Run it after touching any Resources JSON.

## Commands (macOS only)
- App tests: `xcodebuild test -project STT.xcodeproj -scheme STT -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.0'`
- Parity subset: append `-only-testing:STTTests/IntentClassifierCoreMLParityTests`
- Package tests: `cd IntentKit && swift test` (or `VoiceIntentKit`)

## Conventions
- Swift 6 strict concurrency. `NLUEngine`/`IntentClassifierService` are actors; UI-facing
  types are `@Observable @MainActor`. Never revert to `@unchecked Sendable` — see ADRs in
  `docs/project-memory/decisions.md` before changing audio-session or concurrency behavior.
- Locale resolution must go through `SpeechTranscriber.supportedLocale(equivalentTo:)`
  (direct `Locale(identifier:)` crashes on some devices).
- Resources JSON is byte-exact parity-sensitive (`.copy` not `.process` in SPM). Don't
  reformat, re-serialize, or "clean up" resource JSON files.
- `STT/STT/Resources/` and `VoiceIntentKit/.../Resources/` are largely duplicated by
  design (Phase-2 migration); a change to one usually needs mirroring in the other.

## Token-efficiency rules for Claude
- NEVER read model/weight blobs: `*.mlpackage` internals, `weight.bin`, `*.mlmodel`,
  `minilm-vocab.txt`, `*_intent_classifier_weights.json`, `semantic_head.json`,
  `coreml_golden_fixtures.json` (up to 16 MB). Inspect with `jq 'keys'` / `head -c` instead.
- Language packs / schema / lexicon JSON: prefer `jq` queries over full reads.
- For "where is X" questions, check this file and `docs/project-memory/architecture.md`
  before grepping the tree.
