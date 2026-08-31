// swift-tools-version: 6.0
// VoiceAIKit — on-device speech-to-text + intent classification, in one package.
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
    name: "VoiceAIKit",
    // iOS 26+ is required by SpeechAnalyzer / SpeechTranscriber. Version given as a
    // string so it builds regardless of the PackageDescription enum's known cases.
    platforms: [ .iOS("26.0") ],
    products: [
        .library(name: "VoiceAIKit", targets: ["VoiceAIKit"]),
        // The English seed pack, as its OWN library.
        //
        // Separate so that (a) `VoiceAIKit` keeps shipping zero data and
        // cannot read a pack from its own bundle, and (b) an app that downloads
        // every language links only `VoiceAIKit` and carries 0 MB instead of
        // 8.8 MB. With one library every app pays for English, including the
        // ones that will never speak it.
        .library(name: "VoiceAISeedPackEN", targets: ["VoiceAISeedPackEN"]),
    ],
    targets: [
        // The library ships ZERO data.
        //
        // No `resources:` block, and that absence is the acceptance test for the
        // whole work package — `Bundle.module` is not even synthesised for this
        // target, so there is no bundled schema, lexicon, entity table or model
        // for a failure to quietly fall back on. Everything comes from a verified
        // pack the host supplies at runtime (`PackProvider`).
        //
        // A `PrivacyInfo.xcprivacy` briefly lived here, for the `UserDefaults`
        // required-reason API (CA92.1) the locale override used. That override is
        // gone, the target now touches no required-reason API, collects nothing,
        // and is not on Apple's list of commonly used third-party SDKs — the three
        // things that would make a manifest mandatory. So the manifest went too,
        // and with it the one resource that forced `Bundle.module` into existence.
        // `PackageResourceInvariantTests` keeps the guarantee honest either way.
        //
        // What used to be here: 4 `.mlpackage` models, 5 JSON/vocab files and
        // `Resources/LanguagePacks/` — about 29 MB, and the reason a language
        // released after the app shipped could never be used.
        .target(
            name: "VoiceAIKit",
            path: "Sources/VoiceAIKit"
        ),
        // The English seed pack. No dependency on `VoiceAIKit` — it vends a
        // URL and nothing more, so the arrow points app → kit and app → seed,
        // and the kit never learns that a seed exists.
        //
        // `.copy`, never `.process`: copy preserves the directory tree verbatim.
        // The pack's structure IS its data — `capabilities/<id>/responses/<lang>.json`
        // encodes both in the path, `integrity/manifest.sha256` lists every file
        // by path, and `models/intent/en/` holds two different files both named
        // `IntentClassifier.mlpackage`. Flattening breaks all three, and a
        // flattened pack fails its own signature check.
        .target(
            name: "VoiceAISeedPackEN",
            path: "Sources/VoiceAISeedPackEN",
            resources: [.copy("packs")]
        ),

        // Test target — runtime smoke tests + Phase-2 parity tests ported from
        // STTTests. The golden fixture is copied here (test-only, doesn't belong
        // in the library). The tests reach the classifier through the library's
        // public/@testable API, so library resources still resolve via
        // Bundle.module inside the library itself.
        .testTarget(
            name: "VoiceAIKitTests",
            dependencies: ["VoiceAIKit"],
            path: "Tests/VoiceAIKitTests",
            resources: [
                // Expected values captured from the Python engine at a FIXED
                // clock. The pack itself is located by walking up from #filePath
                // rather than being declared here — it is deliberately not an
                // SPM resource, since the point of the refactor is that the
                // package ships no data.
                .copy("Fixtures/reference_expectations.json"),
                // Topic derivation captured from `entities.py::strip_datetime`
                // and `engine.py::_derive_topic`. Same rule: regenerate, never
                // hand-edit.
                .copy("Fixtures/topic_expectations.json"),
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
    // identically to the app at runtime. See VoiceAIKit/MIGRATION.md.
    swiftLanguageModes: [.v5]
)
