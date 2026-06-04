# STT — On-Device Speech-to-Text Module for iOS 26+

A complete, production-grade offline speech-to-text module built on Apple's **SpeechAnalyzer** and **SpeechTranscriber** APIs (iOS 26+). Designed as a hearing aid companion app pipeline:

```
Audio (mic or file) → SpeechAnalyzer (on-device STT) → Text → ONNX Model → Intent
```

No network. No third-party SDKs. No Dialogflow dependency.

---

## Architecture

```
STT/
├── Protocols/
│   ├── AudioInputProvider.swift      ← Open/closed audio source abstraction
│   └── TranscriptionDelegate.swift   ← Interface-segregated callback protocol
├── Audio/
│   ├── AudioSessionManager.swift     ← AVAudioSession + hearing aid detection
│   ├── AudioCaptureService.swift     ← Live mic → AsyncStream<AnalyzerInput>
│   └── FileCaptureService.swift      ← Audio file → AsyncStream<AnalyzerInput>
├── Recognition/
│   └── SpeechRecognitionService.swift ← SpeechAnalyzer + SpeechTranscriber
├── Coordinator/
│   └── TranscriptionCoordinator.swift ← Public API surface
├── Models/
│   ├── TranscriptionResult.swift
│   ├── TranscriptionState.swift
│   ├── TranscriptionError.swift
│   └── AudioInputState.swift
└── Extensions/
    └── AVAudioPCMBuffer+AnalyzerInput.swift
Views/
├── STTTestView.swift              ← Root screen with Live / File tabs
├── LiveTranscriptionView.swift    ← Hero mic screen
├── FileTranscriptionView.swift    ← File picker + transcription
├── LanguageSelectorView.swift     ← Language picker sheet
├── TranscriptionResultCard.swift  ← Glassmorphism result card
├── AudioVisualizerView.swift      ← Real-time waveform
└── Components/
    ├── PulsingMicButton.swift     ← Animated record button
    ├── AudioLevelBar.swift        ← Audio level meter
    └── StatusBadge.swift          ← Mic source indicator
ViewModels/
├── LiveTranscriptionViewModel.swift
└── FileTranscriptionViewModel.swift
STTTests/
├── Mocks/
│   ├── MockAudioInputProvider.swift
│   └── MockTranscriptionDelegate.swift
├── AudioSessionManagerTests.swift
├── SpeechRecognitionServiceTests.swift
└── TranscriptionCoordinatorTests.swift
```

---

## Xcode Integration

### Requirements

- iOS 26.0+
- Swift 6
- Xcode 26+

### Steps

1. **Add files**: Drag the source directories into your Xcode project. Ensure all `.swift` files are added to your app target.

2. **Capabilities** — In your target → Signing & Capabilities:
   - Add **Speech Recognition**
   - Add **Background Modes → Audio, AirPlay, and Picture in Picture** (for background recording)

3. **Info.plist keys** — add both:

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Used to transcribe voice commands for your hearing aid.</string>

<key>NSMicrophoneUsageDescription</key>
<string>Used to capture audio for speech-to-text transcription.</string>
```

4. **Entry point**: The app root is `STTTestView`. Update `STTApp.swift` if needed (already done in this project).

---

## Connecting to an ONNX Intent Classifier

Implement `TranscriptionDelegate` in your coordinator/controller:

```swift
let coordinator = TranscriptionCoordinator()
coordinator.delegate = self

// Delegate method:
func didReceiveFinalResult(_ text: String) {
    let intent = try onnxClassifier.classify(text: text)
    hearingAidController.execute(intent: intent)
}
```

Or use the `AsyncSequence` API:

```swift
for await result in coordinator.results where result.isFinal {
    let intent = try await onnxClassifier.classify(text: result.text)
    hearingAidController.execute(intent: intent)
}
```

---

## Locale Auto-Detection

Priority order on first launch:

1. **UserDefaults override** — from a previous explicit selection
2. **Device locale** — `Locale.current` matched via `SpeechTranscriber.supportedLocale(equivalentTo:)`
3. **Language component** — picks first supported locale with matching language code
4. **Fallback** — `en-IN` → first available locale

> **Critical**: Always use `SpeechTranscriber.supportedLocale(equivalentTo:)` for locale resolution. Passing `Locale(identifier:)` directly to `SpeechTranscriber` crashes on some devices.

To override from code:

```swift
try await coordinator.switchLocale(to: "hi-IN") // saves to UserDefaults automatically
```

---

## Hearing Aid Bluetooth Detection

`AudioSessionManager` promotes hearing aid input automatically. Preferred port types (in order):
- `.bluetoothLE` — Bluetooth LE audio (modern hearing aids)
- `.bluetoothHFP` — Bluetooth Hands-Free Profile
- `.bluetoothA2DP` — Bluetooth stereo

On disconnection mid-session, falls back to built-in mic and fires `audioSessionManager(_:routeDidChangeTo:)`.

---

## UI Screens

### Speech Engine (Root)
Custom pill tab bar switching between **Live** and **File** modes. Header shows `Locale · Audio Route`. Gear icon opens language selector.

### Live Transcription
- Source badge (🎙 iPhone Mic / 🦻 Hearing Aid) with animated green dot
- Large transcript area — partial results in muted white, final results in full white
- 40-bar animated waveform at 30fps
- Pulsing mic button with radiating concentric rings while listening
- Results history: swipeable glassmorphism cards with timestamp, locale, duration, confidence

### File Transcription
- Dashed drop zone → file info card (name, duration, format, size) → Transcribe CTA
- Progress bar with Cancel during processing
- Result card with Copy, Share, and "Transcribe Another"

### Language Selector (Sheet)
- All `SpeechTranscriber.supportedLocales` grouped by region (South Asian, East Asian, European, etc.)
- Search bar
- Auto-detected option at top
- Checkmark on active locale

---

## Running Tests

```bash
xcodebuild test \
  -scheme STT \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.0'
```

### Test Coverage

| Test File | What It Verifies |
|-----------|-----------------|
| `AudioSessionManagerTests` | Default route, delegate wiring, route equality |
| `SpeechRecognitionServiceTests` | Locale resolution priority, unsupported locale throws, availableLocales matches system |
| `TranscriptionCoordinatorTests` | Initial state, file-not-found, provider factory selection, delegate transitions, error descriptors, state semantics |
