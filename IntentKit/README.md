# IntentKit

On-device NLU / Intent Classification SDK for iOS — a modular, Dialogflow-free
replacement that runs entirely offline. Designed to sit downstream of the STT
module (`transcript → intent`), but usable with any text source.

## Install (Swift Package Manager)

```swift
.package(path: "../IntentKit")   // or a git URL
// target dependency: .product(name: "IntentKit", package: "IntentKit")
```

## Use

```swift
import IntentKit

let engine = try await NLUEngine(
    configuration: .coreML(
        model: .bundled(name: "HearingAidIntents"),   // compiled .mlmodelc
        labels: [
            Intent(name: "adjust_volume", domain: "audio_control"),
            Intent(name: "mute",          domain: "audio_control"),
            Intent(name: "change_program", domain: "audio_control"),
        ],
        acceptThreshold: 0.60,
        marginThreshold: 0.15
    )
)

let result = try await engine.classify("turn up the volume in my left ear")

switch result.decision {
case .recognized(let intent, let confidence): break   // act on it
case .ambiguous(let candidates):              break   // ask the user
case .unknown(let reason):                    break   // fallback
}
```

## Module map

| Target | Purpose | Dependencies |
|---|---|---|
| `IntentKit` | Public facade: `NLUEngine`, builder, config | Core, CoreML |
| `IntentKitCore` | Protocols, pipeline, default stages, models | **none** (pure Swift) |
| `IntentKitCoreML` | Core ML + NaturalLanguage backend (default) | Core, CoreML, NaturalLanguage |
| `IntentKitONNX` | Optional ONNX backend | Core, onnxruntime (opt-in) |
| `IntentKitTesting` | Mocks + fixtures | Core |

`IntentKitCore` has **no ML dependency**, so the pipeline, calibrator, and decision
policy unit-test in milliseconds without any model file. Run:

```bash
swift test
```

## Architecture

See [`../docs/IntentKit-NLU-Architecture.md`](../docs/IntentKit-NLU-Architecture.md)
for the full design, diagrams, and rationale.

> This is a reference scaffold. The Core ML backend's `predict` and the bundled
> model interface must be wired to your compiled `.mlmodelc`. Everything else —
> pipeline, policy, calibration, tokenization, embedding — is functional as-is.
