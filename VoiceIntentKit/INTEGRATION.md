# Integrating VoiceIntentKit into a host app

Two halves, and they are independent. **Part 1** gets a session running against a bundled pack —
that is the whole feature, and it needs no server. **Part 2** adds OTA so packs can be updated
without an App Store release.

Do Part 1 first and ship it if you like. Part 2 changes where the pack comes from, not what the
session does with it.

---

## Part 1 — a working session

### 1. Link the package

**File → Add Package Dependencies… → Add Local…**, choose the `VoiceIntentKit` folder.

Add **both** products to your app target:

- `VoiceIntentKit` — the engine
- `VoiceIntentSeedPackEN` — the English pack, ~7 MB

Skip the seed only if your app downloads every language before first use. Without it there is no
offline floor: a fresh install cannot classify anything until its first successful download.

Verify under *Target → General → Frameworks, Libraries, and Embedded Content*.

### 2. Info.plist and capabilities

```
NSMicrophoneUsageDescription        — why you need the microphone
NSSpeechRecognitionUsageDescription — required even when YOU own the microphone
```

Capabilities: Speech Recognition. Add Background Modes → Audio if sessions run in the background.

Deployment target must be **iOS 26.0** or later.

### 3. Tell the SDK where the pack is

```swift
import VoiceIntentKit
import VoiceIntentSeedPackEN

struct AppPackProvider: PackProvider {
    func packURL(for language: String) async throws -> URL {
        guard language == VoiceIntentSeedPackEN.language,
              let seed = VoiceIntentSeedPackEN.url else {
            throw VoiceIntentError.languageUnavailable(
                requested: language,
                available: [VoiceIntentSeedPackEN.language])
        }
        return seed
    }
}
```

`VoiceIntentSeedPackEN.url` is nil when the library is linked but its resource bundle did not
make it into the app. Those are two different failures — "we don't ship that language" and "the
build dropped it" — and collapsing them turns a missing-in-Xcode pack into a misleading "no pack
for 'en'".

For a single language, `StaticPackProvider(language: "en", url: seed)` does the same thing.

### 4. Choose a trust policy

```swift
#if DEBUG
let trust = PackTrustPolicy.unverifiedForTesting
#else
let trust = PackTrustPolicy(
    publicKeys: ["starkey-prod-2026": productionPublicKey],
    refusesDevelopmentPacks: true,
    skipsSignatureVerification: false)
#endif
```

`.unverifiedForTesting` skips signature verification entirely. It is for tests and local pack
authoring. **A release build that reaches it will load any pack anyone can put on disk** —
enforce the split structurally, not by code review.

### 5. Run a session

The shape below is for a host that already owns its audio and its text-to-speech, which is the
usual case for an app with its own recorder. For the simpler case, drop `audioSource`, set
`speaksPrompts: true`, and ignore `provideAudio` and `hostDidFinishSpeaking`.

```swift
let session = VoiceIntentSession(configuration: .init(
    language: .english,
    packProvider: AppPackProvider(),
    trust: trust,
    speaksPrompts: false,                          // your TTS, not ours
    autoStopOnSilence: true,
    audioSource: .appProvided(sampleRate: 16_000)  // your microphone
))

Task {
    for await event in session.events {
        switch event {
        case .stateChanged(let state):
            // Push audio ONLY while listening. Anything else is dropped, which is what
            // stops trailing audio from one turn bleeding into the next.
            state == .listening ? startFeedingAudio() : stopFeedingAudio()

        case .partialTranscript(let text): showCaption(text)
        case .finalTranscript(let text):   commitCaption(text)

        case .turn(let turn):
            switch turn {
            case .followUp(let question, _), .confirmation(let question):
                await speak(question)
                session.hostDidFinishSpeaking()

            case .fulfilled(let intent, let slots, let message, _, _, _):
                dispatch(intent: intent, slots: slots)
                await speak(message)
                session.hostDidFinishSpeaking()

            case .notUnderstood(let intent, _, _):
                dispatch(intent: intent, slots: [:])   // "Default Fallback Intent"
                session.hostDidFinishSpeaking()

            case .interrupted(let cancelled):
                dismissUI(for: cancelled)
            }

        case .error(let message):
            logger.error("\(message)")
        }
    }
}

try await session.start()
```

Then feed the microphone — **Int16, mono, interleaved**, at the sample rate you declared:

```swift
session.provideAudio(pcmData)   // safe to call from a real-time audio thread
```

**`hostDidFinishSpeaking()` is not optional in this mode.** The session stays in `.speaking`
until you call it, deliberately: that is what keeps the microphone shut while your prompt is
still playing, so your own voice is never transcribed as the user's answer. Forget it and the
turn stalls until a 30-second watchdog releases it.

### 6. Record which pack answered

```swift
if let pack = session.loadedPack {
    analytics.log(session: id,
                  modelBundleVersion: pack.version,
                  modelChecksum: pack.checksumRoot,
                  channel: pack.channel)
}
```

Read it from the **session**, not from `VoiceIntentClient.activePackVersion()`. That method
reports what is `Current` on disk, and activation is apply-on-next-build — after an OTA install
the two disagree until the next session starts. When a user reports a misheard command, the pack
that misheard it is the session's.

### 7. Text without a microphone

```swift
let turn = try await session.classify(text: "turn up the volume in my left ear")
```

Same pipeline, no audio. Useful for a keyboard, a test harness, or a shortcut.

---

## Part 2 — OTA updates

The SDK verifies, stages, smoke-tests, activates and rolls back. **It does not download.** You
own the network conversation, because you own the auth, the CDN, the pinning, the retry policy,
and — since a background `URLSession` needs `handleEventsForBackgroundURLSession` on the app
delegate — the background transfer too.

### 1. Implement three protocols

```swift
protocol PackExtractor: Sendable {
    func extract(from source: URL, to destination: URL) throws
}

protocol NLUEngineProvider: Sendable {
    func smokeTest(packRoot: URL, language: String) async throws
    func load(modelPath: URL, vocabularyPath: URL) throws
    var isIdle: Bool { get }
}
```

`PackExtractor` unzips. **It must not modify anything it extracts.** `PackValidator` extracts
first and verifies second, and the Ed25519 signature covers `bundle.json`, which is deliberately
excluded from the checksum table — so a "helpful" edit to that file is a pack whose signature can
no longer verify. This is not hypothetical: a `version`-injecting hotfix in exactly that spot
would have failed every OTA install the day production signing was switched on.

Hoisting a single top-level directory is fine — it moves files, it does not edit them.

`NLUEngineProvider.smokeTest` should be one call:

```swift
func smokeTest(packRoot: URL, language: String) async throws {
    _ = try await VoiceIntentPack.smokeTest(packRoot: packRoot, language: language, trust: trust)
}
```

Pass the **same trust policy the session uses**. A different one here makes the activation gate
check something other than what will actually run, while reading as correct.

`isIdle` gates activation so a pack is never swapped mid-inference. If your app serves through
`VoiceIntentSession` — which loads the freshest pack when it next builds — nothing else holds a
live engine, and `true` is honest.

### 2. Build the client once, at launch

```swift
let storageBase = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

let storage   = try PackStorageController(baseStorageURL: storageBase)
let validator = PackValidator(extractor: AppPackExtractor(), trust: trust)

let client = VoiceIntentClient(
    storage: storage,
    validator: validator,
    engineProvider: AppEngineProvider(),
    seedPackURL: VoiceIntentSeedPackEN.url!)
```

`PackStorageController` appends its own `VoiceIntentKit/Packs` beneath the base you give it.
**Resolve that base in exactly one place** and use it from both the writer here and the
`PackProvider` that reads packs back — computing it twice is how downloaded packs end up
activated somewhere nothing ever looks.

### 3. Download, then hand over

```swift
let temp = try await downloadPack(from: url)          // yours
let manifest = try await client.installer.preparePack(from: temp, language: "en")

while !client.isEngineIdle { try await Task.sleep(for: .seconds(1)) }
try await client.installer.activatePreparedPack(language: "en")
```

`preparePack` extracts, verifies the full trust chain, and stages. `activatePreparedPack` runs
your smoke test and swaps atomically. Either throwing means the previous pack stays `Current` and
the user keeps a working assistant.

### 4. Serve the activated pack

Point your `PackProvider` at the same storage the installer writes to, and fall back to the seed:

```swift
func packURL(for language: String) async throws -> URL {
    if let current = storage.currentPack(for: language),
       (try? VoiceIntentPack.verify(at: current, language: language, trust: trust)) != nil {
        return current
    }
    return try seedURL(for: language)
}
```

`verify` runs the same checks a real load runs, so a corrupt or wrong-language `Current` falls
through to the seed instead of reaching a session that would throw. It is cheap — no content is
read.

Because `VoiceIntentSession` calls the provider every time it builds, **an activation is picked
up by the very next session.** No app restart, no live hot-swap.

---

## Checklist

- [ ] Both products linked; deployment target iOS 26.0+
- [ ] Both usage-description keys present
- [ ] `PackProvider` implemented; seed pack reachable offline
- [ ] Release builds cannot construct `.unverifiedForTesting`
- [ ] `.appProvided`: audio pushed only while `.listening`, `hostDidFinishSpeaking()` on every turn
- [ ] `session.loadedPack` logged once per session
- [ ] Extractor does not modify anything it extracts
- [ ] Storage base resolved in one place, shared by writer and reader
- [ ] Smoke test uses the session's trust policy
