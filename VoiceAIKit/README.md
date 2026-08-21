# VoiceAIKit

On-device speech-to-text and intent classification for iOS, in one package. No network, no
cloud NLU. Microphone in, classified intents and multi-turn dialogue out, through a single
facade.

```swift
let session = VoiceIntentSession(configuration: .init(
    language: .english,
    packProvider: StaticPackProvider(language: "en", url: seedURL),
    trust: myTrustPolicy))

Task { for await event in session.events { handle(event) } }
try await session.start()
```

## The package ships zero data

That is the design, not an accident. `Package.swift` declares no `resources:` block for the
`VoiceAIKit` target, so SwiftPM does not even synthesise a `Bundle.module` for it — there
is no bundled schema, lexicon, entity table or model for a failure to quietly fall back on.

Everything the runtime classifies with comes from a **pack**: a signed directory the host
supplies at run time. What used to be compiled in was ~29 MB of models and JSON, and the
reason a language released after the app shipped could never be used.

Two products:

| Product | What it is |
|---|---|
| `VoiceAIKit` | The engine. Zero data. Link this always. |
| `VoiceAISeedPackEN` | The English pack, ~7 MB, as a resource. Link it only if you want a working first launch with no network. An app that downloads every language links only the kit and carries 0 MB. |

## Requirements

- **iOS 26+** — `SpeechAnalyzer` / `SpeechTranscriber` are iOS 26 APIs, and they are load-bearing.
- Xcode 26+. The package builds in Swift 5 language mode; your app does not have to.
- `Info.plist`: `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
  Speech-recognition authorization is required even when the host owns the microphone.
- Background Modes → Audio, if you run sessions in the background.

`swift test` does not work from a Mac: SwiftPM builds for the host platform, and `AVAudioSession`
and `SpeechAnalyzer` do not exist there. Run the tests against an **iOS Simulator** destination —
open `Package.swift` in Xcode and press Cmd+U, or `xcodebuild test -scheme VoiceAIKit
-destination "id=<simulator udid>"`.

## The whole public API

Thirty-eight types. Everything else — the audio graph, the recogniser, the three-stage
classifier, the dialogue manager, the pack loader — is internal and free to change.

### Running a session

```swift
VoiceIntentSession(configuration:)      // @MainActor
    .events        : AsyncStream<VoiceIntentEvent>
    .state         : VoiceSessionState
    .loadedPack    : PackIdentity?      // nil until the engine is built
    start()  async throws
    stop()
    reset()  async
    classify(text:) async throws -> VoiceIntentTurn   // no microphone
    provideAudio(_ data: Data)                        // .appProvided only
    hostDidFinishSpeaking()                           // external TTS only
```

`VoiceIntentConfiguration` carries `language`, `packProvider`, `trust`, `speaksPrompts`,
`autoStopOnSilence`, `loadsSemanticRescue`, `audioSource`, and optional overrides for
`fuzzyStopwords`, `trailingFunctionWords`, `commandSilence`, `slotAnswerSilence`.

`packProvider` and `trust` have **no defaults**, deliberately. Every default for the first is a
language, and a wrong one is a session that confidently speaks the wrong tongue; a default for
the second is a session that verifies nothing, and that default would ship.

### The event stream

One stream drives the whole UI.

```swift
enum VoiceIntentEvent {
    case stateChanged(VoiceSessionState)   // idle preparing listening thinking speaking stopped
    case partialTranscript(String)
    case finalTranscript(String)
    case turn(VoiceIntentTurn)
    case error(message: String)
}

enum VoiceIntentTurn {
    case followUp(question: String, collected: [String: String])
    case confirmation(question: String)
    case fulfilled(intent: String, slots: [String: String], message: String,
                   confidence: Double, viaSemanticRescue: Bool, stages: VoiceIntentStages?)
    case notUnderstood(intent: String, confidence: Double, stages: VoiceIntentStages?)
    case interrupted(cancelledIntent: String)
}
```

`.notUnderstood` carries an **intent name**, not a URL — the pack's own fallback label, which is
`Default Fallback Intent` for every pack shipping today. Dispatch it through your existing
intent table; it needs no branch of its own. What happens to an unrecognised utterance next is
yours to decide, and the address is not something an unsigned pack should get to choose.

### Supplying the pack

```swift
protocol PackProvider: Sendable {
    func packURL(for language: String) async throws -> URL
}

StaticPackProvider(language: "en", url: seedURL)
StaticPackProvider(["en": enURL, "da": daURL])
```

The SDK never opens a socket and never scans a bundle. You hand it a local file URL; it verifies
before it trusts a byte. Auth, CDN URLs, certificate pinning, cellular policy, background
transfer and MDM pre-provisioning are all yours — and background `URLSession` needs
`handleEventsForBackgroundURLSession` on your app delegate, which an SDK cannot own cleanly.

### Trust

```swift
PackTrustPolicy(publicKeys: ["prod-2026": keyBytes],
                refusesDevelopmentPacks: true,
                skipsSignatureVerification: false)

PackTrustPolicy.unverifiedForTesting     // tests and local pack authoring ONLY
```

The keys are yours, not the SDK's — pinning them here would mean an SDK release to rotate one.

### Pack-level operations, without a session

```swift
VoiceIntentPack.verify(at:language:trust:policy:) throws -> PackIdentity
VoiceIntentPack.smokeTest(packRoot:language:trust:policy:probe:) async throws -> PackIdentity

struct PackIdentity {
    let bundleID, version, checksumRoot, keyID, channel, compilerVersion, createdAt: String
    let languages: [String]
}
```

`verify` runs the same checks a real load runs — signature chain, every file digest,
`min_runtime_contract`, the development-pack refusal, report-card gates, language availability —
and stops before reading content. It answers *"would this load?"*, which is the question a
`PackProvider` is actually asking.

`smokeTest` loads a pack exactly as a live session would and runs one classification. A pack can
pass every cryptographic check and still be unloadable on this device; only loading it can tell
you. Throwing is the signal to abort an OTA activation.

### OTA

`VoiceIntentClient`, `NLUPackInstaller`, `PackStorageController`, `PackValidator`, and the three
protocols you implement: `PackProvider`, `PackExtractor`, `NLUEngineProvider`. See
[`INTEGRATION.md`](INTEGRATION.md).

## Two integration shapes

**The package owns the microphone** (`audioSource: .microphone`, the default). It opens the mic,
configures and activates the `AVAudioSession`, handles route changes and interruptions, and can
speak prompts itself.

**The host owns the microphone** (`audioSource: .appProvided(sampleRate:)`). You push Int16 mono
PCM with `provideAudio(_:)`; the package touches no `AVAudioSession` state and requests no
microphone permission. This is the shape for an app that already owns its audio — a hearing-aid
stream, a call, a push-to-talk button.

In that mode `speaksPrompts` must be `false`: you own the audio session, so the package's TTS
cannot be relied on to play. Combining them throws
`VoiceIntentConfigurationError.internalTTSUnavailableWithAppProvidedAudio` from `start()` rather
than dropping prompts silently. Speak prompts yourself from the `.turn` events, then call
`hostDidFinishSpeaking()` — the session deliberately does not reopen the microphone until you
do, so your own voice is never captured as the user's answer.

Feed audio only while `state == .listening`. Anything pushed outside that is dropped, so trailing
audio from one turn cannot bleed into the next.

## What it refuses to do

Refusing is a feature here; the alternative is a hearing aid acting on a guess.

- **No silent language fallback.** A missing, unsigned, tampered or wrong-language pack throws.
  The predecessor answered a broken pack by substituting English, which is indistinguishable from
  success for an English user and wrong in the hands of everyone else.
- **No fallback chain.** `.notUnderstood` is reported, never acted on.
- **No invented pack data.** If a pack omits a field the runtime needs, it says so; it does not
  supply a default that looks reasonable.
- **No unverified pack.** Ed25519 over `manifest.sha256 ‖ bundle.json`, `checksums_root` binding
  the two, then every file's digest — all before a byte is parsed.

## Resilience

A CoreML model that fails to load falls back to the pure-Swift TF-IDF path. Missing MiniLM
artifacts skip Stage 3. A corrupt OTA pack rolls back, and the bundled seed is the floor a broken
pack can never take away.
