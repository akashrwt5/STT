// swift-tools-version: 6.0
// IntentKit — On-device NLU / Intent Classification SDK
//
// Modular by design: `IntentKitCore` is pure Swift with NO ML dependency, so the
// pipeline, policies, and stages unit-test in milliseconds without any model files.
// Backends (Core ML, ONNX) are separate targets a consumer opts into.

import PackageDescription

let package = Package(
    name: "IntentKit",
    platforms: [
        .iOS(.v17), .macOS(.v14)   // NaturalLanguage embeddings; raise to .iOS(.v26) if using SpeechAnalyzer bridge
    ],
    products: [
        // The one product most apps import.
        .library(name: "IntentKit", targets: ["IntentKit"]),
        // Pure-Swift contracts + engine, for apps supplying their own backend.
        .library(name: "IntentKitCore", targets: ["IntentKitCore"]),
        // Test doubles for consumers' own test suites.
        .library(name: "IntentKitTesting", targets: ["IntentKitTesting"]),
    ],
    dependencies: [
        // Opt-in only. Uncomment to enable the ONNX backend target below.
        // .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.17.0"),
    ],
    targets: [
        // MARK: Public facade
        .target(
            name: "IntentKit",
            dependencies: ["IntentKitCore", "IntentKitCoreML"]
        ),

        // MARK: Pure-Swift core (no ML, no platform frameworks beyond Foundation)
        .target(
            name: "IntentKitCore",
            dependencies: []
        ),

        // MARK: Default backend — Core ML + NaturalLanguage
        .target(
            name: "IntentKitCoreML",
            dependencies: ["IntentKitCore"]
        ),

        // MARK: Optional ONNX backend (enable dependency above, then uncomment)
        // .target(
        //     name: "IntentKitONNX",
        //     dependencies: [
        //         "IntentKitCore",
        //         .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
        //     ]
        // ),

        // MARK: Test doubles + fixtures
        .target(
            name: "IntentKitTesting",
            dependencies: ["IntentKitCore"]
        ),

        // MARK: Tests
        .testTarget(
            name: "IntentKitCoreTests",
            dependencies: ["IntentKitCore", "IntentKitTesting"]
        ),
    ]
)
