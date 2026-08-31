// swift-tools-version: 6.0
// VoiceAIKit — on-device speech-to-text and intent classification.
//
// The package is language-neutral: all language-specific data comes from a pack the
// host supplies at runtime.

import PackageDescription

let package = Package(
    name: "VoiceAIKit",
    // Keep the deployment target as a string so this remains compatible across
    // PackageDescription versions that may not expose a dedicated iOS 26 case.
    platforms: [.iOS("26.0")],
    products: [
        .library(
            name: "VoiceAIKit",
            targets: ["VoiceAIKit"]
        ),
        // Separate product so apps that only depend on VoiceAIKit do not link or bundle
        // a seed pack they will never use.
        .library(
            name: "VoiceAISeedPackEN",
            targets: ["VoiceAISeedPackEN"]
        ),
    ],
    targets: [
        // The engine intentionally declares no resources. Declaring one would synthesise
        // Bundle.module and give language-specific data somewhere to live inside the core
        // library. PackageResourceInvariantTests fails the build if any non-source file
        // appears under Sources/VoiceAIKit.
        .target(
            name: "VoiceAIKit",
            path: "Sources/VoiceAIKit"
        ),
        // This target exists only to carry the seed pack, which is what keeps the engine
        // free of language-specific data. It does not depend on VoiceAIKit; it only vends
        // the pack URL.
        //
        // Use .copy, never .process. The pack's directory structure is part of its
        // integrity contract: integrity/manifest.sha256 records every file by path, so
        // processing or flattening the tree would invalidate the pack's signature.
        .target(
            name: "VoiceAISeedPackEN",
            path: "Sources/VoiceAISeedPackEN",
            resources: [.copy("packs")]
        ),
        // SwiftPM warns about any non-source file it finds in a target. The tests read
        // these fixtures straight from disk, so exclude them rather than bundling them.
        .testTarget(
            name: "VoiceAIKitTests",
            dependencies: ["VoiceAIKit"],
            path: "Tests/VoiceAIKitTests",
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
