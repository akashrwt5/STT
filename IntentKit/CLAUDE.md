# IntentKit (SPM package)

Reusable on-device NLU SDK. Target layout is deliberate — keep the boundaries:
- `IntentKitCore` — pure Swift (Foundation only). Pipeline, stages, policies, protocols.
  Must stay free of CoreML/NaturalLanguage imports so it unit-tests in ms without models.
- `IntentKitCoreML` — the only target allowed to import CoreML/NaturalLanguage.
- `IntentKitTesting` — mocks/fixtures for consumers' tests (depends on Core only).
- `IntentKit` — facade product (Core + CoreML).

Tests: `swift test` from this directory (macOS 14+/Xcode required; not runnable on Linux
because IntentKitCoreML imports CoreML unguarded).

When adding a stage or backend: define the protocol in Core, implement in a backend
target, wire via `NLUEngineBuilder`. New Core code must not add platform framework imports.
