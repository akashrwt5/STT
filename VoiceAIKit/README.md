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

## The engine ships zero data — the pack is a separate product

The package contains **two products**, and only one of them carries anything:

| Product | What it is |
|---|---|
| `VoiceAIKit` | The engine. Carries no data at all. Link this always. |
| `VoiceAISeedPackEN` | The English seed pack, as a resource. Opt-in. |

`Package.swift` declares no `resources:` block for the **`VoiceAIKit` target**, so SwiftPM does not
even synthesise a `Bundle.module` for it — there is no bundled schema, lexicon, entity table or
model for a failure to quietly fall back on. That is the design, not an accident.

The seed is a **separate target** precisely so that linking it is a decision. Link it if you want a
working first launch with no network. An app that downloads every language before first use links
only the engine and carries nothing — with one combined library every app would pay for English,
including the ones that will never speak it.

Everything the runtime classifies with comes from a **pack**: a signed directory the host supplies
at run time. What used to be compiled into the engine was ~29 MB of models and JSON, and the reason
a language released after the app shipped could never be used.

## How the pieces fit

One direction of travel, and each folder owns one leg of it.

```
    microphone ──►  Core/  ──►  NLU/  ──►  Facade/  ──►  your app
                  audio→text  text→intent   events

                                 ▲
                                 │ tables, models, lexicon
                                 │
                               Pack/  ◄── OTA/  ◄── your download layer
                            verify+load    install
```

- **`Core/`** turns microphone audio into a final transcript. It knows nothing about intents.
- **`NLU/`** turns that transcript into an intent, fills slots, and runs multi-turn dialogue.
  It knows nothing about microphones or file formats.
- **`Pack/`** verifies a signed pack on disk and projects it into the tables `NLU/` runs on.
  This is the only code that understands the pack format.
- **`OTA/`** puts new packs on disk safely — validate, smoke-test, atomically activate, roll back.
  It never touches a live session.
- **`Facade/`** is everything you import. It owns the state machine that ties a turn together:
  listen → classify → speak → listen again.

The arrow from `Pack/` into `NLU/` is one-way and happens **once, at session start**. That is why
activation is apply-on-next-build: a running session keeps the pack it bound, and the next one
picks up whatever is `Current`.

## Source layout

`Sources/VoiceAIKit/` — 52 files. Nothing here is public except what `Facade/` and `OTA/` expose.

| Folder | Why it exists | What is in it |
|---|---|---|
| **`Facade/`** <br><sub>6 files, 1.4k lines</sub> | The only surface you touch. | `VoiceIntentSession` (the turn state machine), `VoiceIntentClient` (OTA entry point), `VoiceIntentTypes` (events, turns, configuration), `PackProvider`, `VoiceIntentPack` (verify / smoke-test without a session), `PackIdentity`. |
| **`Core/`** <br><sub>19 files, 3.2k lines</sub> | Audio in, text out. The whole STT half. | `Audio/` — `AVAudioSession`, mic capture, VAD/silence detection, buffer conversion, file playback. `Recognition/` — the `SpeechAnalyzer` wrapper and `EndpointDecider` (the pure "should we commit this transcript now?" maths). `Coordinator/` — orchestration. `Models/`, `Protocols/`, `Extensions/`. |
| **`NLU/Engine/`** <br><sub>7 files, 1.2k lines</sub> | Text in, intent out. No audio, no file formats. | `NLUEngine` (an actor: classification, slot filling, confirmations), `NLUContext` (conversation state), `ConfirmationGate`, `ConversationSpeaker` (TTS), `NLUResponse`, `SlotFormatting`, `NLUProtocols`. |
| **`Pack/Schema/`** <br><sub>4 files, 1.2k lines</sub> | Typed models of the pack's **on-disk format**. | `NLUBundle` (`bundle.json`, decoded strictly), `PackSections`, `PackLexicon`, `ResolvedPack`. |
| **`Pack/Integrity/`** <br><sub>2 files, 432 lines</sub> | The trust chain, in one place. | `PackIntegrity` (Ed25519 + per-file SHA-256), `VoiceIntentError` (everything a load can refuse for). |
| **`Pack/Loader/`** <br><sub>8 files, 2.7k lines</sub> | Pack → runtime. Verified bytes become working objects. | `BundleDataLoader`, `PackEngineFactory`, `DialogSchema` (the engine-facing projection the factory builds), and the pack-driven `PackIntentClassifier`, `PackEntityExtractor`, `PackSlotResolver`, `PackTFIDFVectorizer`, `PackDateTimeParser`. |
| **`OTA/`** <br><sub>5 files, 848 lines</sub> | Getting a new pack onto disk without ever breaking the one that works. | `Installer/NLUPackInstaller` (an actor: prepare → smoke-test → activate), `Validation/PackValidator`, `Storage/PackStorageController` (versioned dirs + atomic symlink swap + rollback), `Models/`. |
| **`Diagnostics/`** <br><sub>1 file</sub> | DEBUG memory instrumentation. | `MemoryProbe` — walks Mach VM regions to separate dirty (jetsam-charged) from clean/file-backed memory. Used to characterise speech-model loading cost. |

Two names worth explaining, because neither is obvious:

- **`Pack/Loader/DialogSchema.swift`** is not the pack format — it is the projection
  `PackEngineFactory.schema(from:)` builds *from* a verified pack, once the language is known.
  It sits in `Loader/`, not `Schema/`, next to the only thing that constructs it.
- **`Core/`** is the one folder whose name says "important" rather than what it holds. Everything
  in it is the speech-to-text pipeline. Renaming it to `Speech/` has been considered and deferred.

## Requirements

- **iOS 26+** — `SpeechAnalyzer` / `SpeechTranscriber` are iOS 26 APIs, and they are load-bearing.
- Xcode 26+. The package builds in **Swift 5 language mode**; your app does not have to, and
  most hosts never notice. It is pinned deliberately, not left behind — see
  [Swift language mode](#swift-language-mode-pinned-to-5) for what it costs you.
- `Info.plist`: `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
  Speech-recognition authorization is required even when the host owns the microphone.
- Background Modes → Audio, if you run sessions in the background.

`swift test` does not work from a Mac: SwiftPM builds for the host platform, and `AVAudioSession`
and `SpeechAnalyzer` do not exist there. Run the tests against an **iOS Simulator** destination:

```bash
xcodebuild test -scheme VoiceAIKit -destination "id=<simulator udid>"
```

or open `Package.swift` in Xcode and press Cmd+U. The `VoiceAIKit` scheme runs `VoiceAIKitTests`
through the checked-in `.swiftpm/VoiceAIKit.xctestplan`; the test target itself belongs to no
product, because SwiftPM does not allow test targets in `products:`..

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

## How OTA works

OTA is how a **new pack gets onto disk safely**. It is entirely separate from how a session
*reads* one — you can ship without any of it and update packs with the App Store instead.

### What you implement, what the SDK implements

The SDK does no networking and unzips nothing. Three protocols are yours:

| You implement | Because |
|---|---|
| `PackProvider` | Auth, CDN URLs, cert pinning, cellular policy, background transfer. A background `URLSession` needs `handleEventsForBackgroundURLSession` on your app delegate, which an SDK cannot own cleanly. |
| `PackExtractor` | ZIP extraction, with whatever library you already use. Keeps the SDK dependency-free. |
| `NLUEngineProvider` | Runs the smoke test, and answers `isIdle` so activation never interrupts a live conversation. |

### The install flow

```
   your download layer
          │  .zip / .nlu on disk
          ▼
   installer.preparePack(from:language:)          state: .validating
          │  clean staging/  →  your PackExtractor unzips
          │  PackIntegrity: Ed25519 signature, then every file's SHA-256
          ▼
   PackIdentity returned                          state: .readyToActivate
          │
          ▼
   installer.activatePreparedPack(language:)      state: .validating (claimed)
          │  1. token guard — staging's checksums_root still matches what we verified
          │  2. your NLUEngineProvider.smokeTest() loads the staged pack for real
          │  3. commit: staging/ → <version>/, then Current symlink swapped
          ▼
                                                  state: .active
```

Three things that are load-bearing:

**The smoke test is a dress rehearsal, not a checksum.** It receives the pack *root* and loads it
through the exact path a live session uses. A pack can pass every cryptographic check and still be
unloadable on this device — a CoreML model the OS refuses, a runtime feature that is missing. Only
loading it can tell you. If it throws, the pack never becomes `Current`.

**The token guard exists because staging can be rewritten.** The cached identity is matched on
`checksums_root` — the digest the signature covers — not on `version`. Two different builds can
carry the same version string, so a version match proves nothing about the bytes.

**Activation is apply-on-next-build.** A running `VoiceIntentSession` keeps the pack it bound at
`start()`. `client.activePackVersion(for:)` reports what is on **disk**; `session.loadedPack`
reports what is **running**. After an install they deliberately disagree until the next session
starts — when a user reports a misheard command, the pack that misheard it is `session.loadedPack`.

### On-disk layout

```
{baseStorageURL}/VoiceAIKit/Packs/en/
├── Current ─────► 1.0.39        symlink, swapped with POSIX rename(2)
├── 1.0.39/                      the active pack
├── 1.0.38/                      kept: the rollback target
├── staging/                     wiped at the start of every prepare
└── .rollback_target             records the known-good previous version
```

The swap is a single `rename(2)`, which replaces the destination atomically. A reader resolving
`Current` always sees either the old target or the new one — never a missing link.

`PackRetentionPolicy(keepPreviousCount: 1)` keeps the version immediately before the active one.
That is load-bearing twice over: it is the rollback target, **and** it protects a session that
resolved the previous `Current` moments before a swap and is still loading its files.

### Rollback and the floor

`client.start(for:)` tries the active OTA pack. If it will not load, it rolls back to the recorded
known-good version and tries again, up to three times. If every OTA pack fails, it loads the
**bundled seed pack**.

That fallback never throws past `start()`. A broken OTA pack must not be able to prevent a
perfectly good seed pack from loading — which is exactly what happened before, when a rollback with
no previous version propagated `noPreviousVersionAvailable` out of `start()` and bricked startup.

### What a pack looks like inside

```
pack-en-v1.0.39-ios/
├── bundle.json                  manifest: version, checksums_root, languages, models,
│                                engine_compat, channel, report_card_summary, …
├── integrity/
│   ├── manifest.sha256          every file, by path, with its digest
│   └── signature.sig            Ed25519 over manifest.sha256 ‖ bundle.json
├── capabilities/<id>/           one directory per capability (device.volume, reminders, …)
│   ├── capability.json          the actions it exposes
│   ├── workflows.json           intents: slots, completion, confirmation
│   └── responses/<lang>.json    the per-language text those keys resolve to
├── models/intent/               the TF-IDF + CoreML classifier
├── models/semantic_head/        Stage 3, when the pack enables it
├── lexicons/<lang>.json         affirmative/negative words, stopwords
├── keywords/<lang>.json         Stage 0 regex triggers
├── entities/shared/             gazetteers
├── runtime/policies.json        thresholds, confirmation gates
└── meta/                        lineage, report card
```

The directory tree **is** the data: `capabilities/<id>/responses/<lang>.json` encodes both in its
path, and `integrity/manifest.sha256` lists every file by path. This is why the seed target
declares `.copy("packs")` and never `.process` — flattening breaks the structure, and a flattened
pack fails its own signature check.

Step-by-step host code is in [`INTEGRATION.md`](INTEGRATION.md).

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

## Swift language mode: pinned to 5

`Package.swift` ends with `swiftLanguageModes: [.v5]`. Your app is unaffected — language mode is
per-target, so a Swift 6 app links this happily. But you should know why the line is there, because
the reason is not laziness and the consequence is real.

### What happens without it

Removing the line makes SwiftPM build the package under Swift 6 strict concurrency. Compiling is
the easy part; it has been done. The problem is at runtime:

> On device (iPhone 17 Pro Max, iOS 26), roughly **one second after the microphone starts**:
> `EXC_BREAKPOINT` (`brk #0x1`) on `com.apple.RealtimeMR_ForceQueue`, in
> `_dispatch_assert_queue_fail`, **inside `Speech.framework`**.

The same code, byte-for-byte, does not crash when built in Swift 5 mode.

### Why

Three things have to line up.

**Every piece of async code runs on an *executor*** — the thing that decides which thread it lands
on. Most actors use the shared cooperative thread pool, and any free thread will do.

**`SpeechAnalyzer` is not most actors.** It pins itself to one specific queue,
`com.apple.RealtimeMR_ForceQueue`. Audio has hard deadlines: a buffer late is a glitch, so Apple
binds the analyzer to a real-time queue rather than letting it float.

**Apple guards that with `dispatch_assert_queue()`** — "am I on the queue I am supposed to be on?"
If not, it traps. That `EXC_BREAKPOINT` is not memory corruption or a bug in your code; it is a
deliberate alarm saying *the threading contract was broken*.

Now the actual failure. Your code `await`s the analyzer's async API. After every `await`, Swift
decides which thread to resume on:

- **Swift 5** resumed back onto the analyzer's own queue. The assertion passed.
- **Swift 6** is stricter about which code counts as `nonisolated` — and `nonisolated` async code
  runs on the generic cooperative pool, not on any particular queue. Some of the analyzer's
  internal callbacks therefore resume on a pool thread instead of the real-time queue, the
  assertion fires, and the process traps.

That is also why the crash arrives a second in rather than at setup. Setup is direct calls; the
callbacks that keep firing once real audio flows are where the resumption thread matters.

**`@unchecked Sendable` and `nonisolated(unsafe)` do not fix this.** They silence the *compiler*.
They do not change *runtime scheduling*. Getting the package to compile under Swift 6 and getting
it to stop crashing are two different projects.

### What this costs you

The package has never been validated under Swift 6 strict concurrency, so its `Sendable`
conformances are promises rather than compiler-checked facts. Six internal types are
`@unchecked Sendable`; two of them — `PackStorageController` and `PackValidator` — are public.
If your app runs in Swift 6 mode, it inherits those promises unverified.

Nothing here is a landmine for a host. It is a known Apple framework constraint, worked around
deliberately, with the diagnosis written down.

### The real fix, when someone does it

Take the choice away from Swift: route the analyzer's calls through an isolated helper that
respects its custom executor, or place explicit `Task.detached` boundaries, inside
`SpeechRecognitionService`'s task group. A separate engineering task, not a migration blocker.

Note that two `deinit`s — `AudioSessionManager` and `VoiceIntentSession` — read isolated stored
state, which Swift 5 permits and Swift 6 does not. A migration needs `isolated deinit`
(SE-0371, Swift 6.1+) or a restructure there.

### How much of this is measured

**Measured:** the crash, reproduced on device; the stack inside `Speech.framework`; the queue name;
and that switching language mode was the only change. Three other fixes were tried first and all
failed the same way — they are recorded in [`MIGRATION.md`](MIGRATION.md) as rejected diagnoses.

**Inferred:** exactly which hop the Swift runtime schedules differently. `Speech.framework` is
closed source, so this is the best available explanation rather than a verified trace. Worth
knowing if you ever attempt the migration and the symptom differs.
