// swift-tools-version: 6.0
// VoiceIntentKit — on-device speech-to-text + intent classification, in one package.
//
// Single-language by design: whichever language's models/overlays are bundled (and
// selected via `VoiceIntentConfiguration.language`) is the language the package
// speaks. The code itself is language-neutral.
//
// This is a SELF-CONTAINED copy of the app's STT + NLU implementation, adapted for
// reuse (Bundle.module resources, one public facade). The app's own sources are left
// untouched; see MIGRATION.md for the Phase-2 plan to make this the single source.

import PackageDescription

let package = Package(
    name: "VoiceIntentKit",
    // iOS 26+ is required by SpeechAnalyzer / SpeechTranscriber. Version given as a
    // string so it builds regardless of the PackageDescription enum's known cases.
    platforms: [ .iOS("26.0") ],
    products: [
        .library(name: "VoiceIntentKit", targets: ["VoiceIntentKit"]),
    ],
    targets: [
        .target(
            name: "VoiceIntentKit",
            path: "Sources/VoiceIntentKit",
            // The now-empty Multilingual/ folder (its files were flattened to the
            // Resources root to match the code's flat Bundle lookups) — exclude so
            // SwiftPM doesn't flag it as an undeclared resource.
            exclude: ["Resources/Multilingual"],
            resources: [
                // CoreML models — `.process` so Xcode/SwiftPM compiles each
                // .mlpackage → .mlmodelc (the code's first-choice lookup). If a
                // model fails to compile, the pure-Swift TF-IDF/JSON fallback paths
                // keep Stage 2 working.
                .process("Resources/IntentClassifier.mlpackage"),
                .process("Resources/IntentClassifier_multilingual.mlpackage"),
                .process("Resources/MiniLMEmbedder.mlpackage"),
                .process("Resources/SemanticHead.mlpackage"),

                // Weights / vocab / schema — `.copy` for byte-exact determinism
                // (parity fixtures depend on exact JSON).
                .copy("Resources/intent_classifier_weights.json"),
                .copy("Resources/multilingual_intent_classifier_weights.json"),
                .copy("Resources/multilingual_intent_labels.json"),
                .copy("Resources/calibration.json"),
                .copy("Resources/semantic_head.json"),
                .copy("Resources/minilm-vocab.txt"),
                .copy("Resources/nlu_schema.json"),
                .copy("Resources/nlu_entities.json"),

                // Per-language overlays — kept as a subdirectory because the code
                // looks them up with `subdirectory: "Localization"`.
                .copy("Resources/Localization"),
            ]
        ),
        // Test target — runtime smoke tests + Phase-2 parity tests ported from
        // STTTests. The golden fixture is copied here (test-only, doesn't belong
        // in the library). The tests reach the classifier through the library's
        // public/@testable API, so library resources still resolve via
        // Bundle.module inside the library itself.
        .testTarget(
            name: "VoiceIntentKitTests",
            dependencies: ["VoiceIntentKit"],
            path: "Tests/VoiceIntentKitTests",
            resources: [
                .copy("Resources/coreml_golden_fixtures.json"),
            ]
        ),
    ],
    // Match the STT app's SWIFT_VERSION = 5 language mode.
    //
    // Under Swift 6 strict concurrency, iOS 26's `SpeechAnalyzer` (which uses a
    // custom serial executor on `com.apple.RealtimeMR_ForceQueue`) trips a
    // `dispatch_assert_queue_fail` on that queue mid-live-session. The app's copy
    // of the exact same code runs fine because the app builds in Swift 5 mode.
    // Aligning the package to Swift 5 keeps the code byte-copyable and behaves
    // identically to the app at runtime. See VoiceIntentKit/MIGRATION.md.
    swiftLanguageModes: [.v5]
)
