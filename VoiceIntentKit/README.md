# VoiceIntentKit

On-device **speech-to-text + intent classification** in one Swift package. No network, no Dialogflow. Drop it into any iOS 26+ app, point it at a bundled language model, and get classified intents from the microphone through a single API.

It is a **self-contained, reusable copy** of the STT + NLU stack from the STT app, adapted for packaging: resources load from `Bundle.module`, and the entire pipeline (audio capture, `SpeechAnalyzer` transcription, 3-stage classifier, multi-turn dialog manager, entity extraction, TTS) sits behind one facade — `VoiceIntentSession`.

## Design constraint: one model, one language

A session speaks exactly **one language**, decided at construction time by which model/overlays are bundled and selected. English is fully self-contained; `fr`, `de`, `da` ship with overlays and use the multilingual classifier. The code itself is language-neutral — swap the bundled assets and the same code speaks that language.

## The entire API

```swift
import VoiceIntentKit

let session = VoiceIntentSession(
    configuration: .init(
        language: .english,        // or .language(code: "fr", locale: "fr-FR")
        speaksPrompts: true,       // speak follow-up questions, auto-listen for answers
        autoStopOnSilence: true,   // end a turn shortly after the user stops speaking
        loadsSemanticRescue: true  // load MiniLM Stage-3 (~16 MB)
    )
)

// Observe one stream for everything: transcripts, dialog turns, state, errors.
Task {
    for await event in session.events {
        switch event {
        case .partialTranscript(let text): print("… \(text)")
        case .finalTranscript(let text):   print("→ \(text)")
        case .turn(let turn):
            switch turn {
            case .followUp(let q, _):          print("Assistant asks: \(q)")
            case .confirmation(let q):         print("Confirm? \(q)")
            case .fulfilled(let intent, let slots, _, let conf, _):
                print("Intent: \(intent) \(slots) (\(conf))")
            case .notUnderstood(let url, _):   print("Fallback → \(url)")
            case .interrupted(let cancelled):  print("Cancelled: \(cancelled)")
            }
        case .stateChanged(let s):         print("state: \(s)")
        case .error(let message):          print("error: \(message)")
        }
    }
}

try await session.start()   // begins listening
// … later …
session.stop()
```

Text-only classification (no microphone), for keyboards or tests:

```swift
let turn = await session.classify(text: "turn up the volume in my left ear")
```

That's the whole surface: `init`, `events`, `start()`, `stop()`, `reset()`, `classify(text:)`. Everything else is internal.

## What's inside (not part of the public API)

```
Sources/VoiceIntentKit/
├── Facade/        VoiceIntentSession + public types  ← the only thing you import
├── Core/          STT: audio capture, SpeechAnalyzer, coordinator, models
├── NLU/           3-stage classifier (keyword → TF-IDF/CoreML → MiniLM)
│   └── NLUCore/   dialog manager, entity extractor, schema, localization, TTS
└── Resources/     .mlpackage models + weights/vocab JSON + Localization overlays
```

Resilience: if a CoreML model fails to load, Stage 2 falls back to the pure-Swift TF-IDF/JSON path; if the MiniLM artifacts are missing, Stage 3 is skipped. The package still classifies.

## Requirements

- iOS 26+ (required by `SpeechAnalyzer` / `SpeechTranscriber`), Swift 6, Xcode 26+.
- Host app Info.plist: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.
- Capabilities: Speech Recognition (and Background Modes → Audio if used in background).

## Integrating into the STT app (the third "Package" option)

See [`INTEGRATION.md`](INTEGRATION.md) for the exact Xcode steps to add this local package and wire the third picker option on the first screen, plus the Phase-2 plan to make this package the single source of truth.
