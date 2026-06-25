# Multilingual NLU Pipeline — Implementation Plan

**Branch:** `claude/coreml-temperature-ios`  
**Repo:** `akashrwt5/STT`  
**Last audited:** commit `88b5215` (branch HEAD at time of analysis)

This document is the single source of truth for the agent (or engineer) executing this work. Every finding is grounded in the actual files at the branch HEAD — no assumptions.

---

## 1. Current State (What the Branch Actually Contains)

### 1.1 Resources — Multilingual artifacts are present

`STT/STT/Resources/Multilingual/` exists as a directory entry in the tree and contains:

| File | Size | Status |
|------|------|--------|
| `IntentClassifier_multilingual.mlpackage` | (dir) | Present — source unknown, needs regeneration from exporter |
| `multilingual_intent_classifier_weights.json` | 8.6 MB | Present — byte-verify against IntentClassifier repo |
| `multilingual_intent_labels.json` | 1.3 KB | Present |

**Xcode group vs folder reference:** The `Multilingual` entry appears as a plain `dir` type in the GitHub tree (not a `.xcassets`). Until you open Xcode you cannot confirm whether it is a Yellow Group (files flatten into bundle root) or a Blue Folder Reference (files land under `Multilingual/` inside the bundle). This matters for `Bundle.main.url(forResource:withExtension:)` — a folder reference requires `subdirectory: "Multilingual"`. The agent must check `STT.xcodeproj/project.pbxproj` for the `Multilingual` group entry and note the `lastKnownFileType` / `sourceTree` to confirm.

### 1.2 IntentClassifierService.swift — CONTAMINATED (Priority 1 fix)

File: `STT/STT/Services/IntentClassifierService.swift`

The `init()` currently loads **multilingual** resources:

```swift
// WRONG — currently in init():
let intentURL = Bundle.main.url(forResource: "IntentClassifier_multilingual", withExtension: "mlmodelc")
             ?? Bundle.main.url(forResource: "IntentClassifier_multilingual", withExtension: "mlpackage")
// ...
let jsonURL = Bundle.main.url(forResource: "multilingual_intent_classifier_weights",
                              withExtension: "json")
```

This must be restored to the English resources:

```swift
// CORRECT — what it must be after cleanup:
let intentURL = Bundle.main.url(forResource: "IntentClassifier", withExtension: "mlmodelc")
             ?? Bundle.main.url(forResource: "IntentClassifier", withExtension: "mlpackage")
// ...
let jsonURL = Bundle.main.url(forResource: "intent_classifier_weights",
                              withExtension: "json")
```

No other logic changes. The `fatalError` message text should also reference `intent_classifier_weights.json` not the multilingual name.

### 1.3 NLUEngine.swift — Concrete dependency (must be inverted)

File: `STT/STT/Services/NLU/NLUEngine.swift`

```swift
// CURRENT — concrete type:
public actor NLUEngine {
    private let classifier: IntentClassifierService

    public init(
        schema: NLUSchema = .loadFromBundle(),
        classifier: IntentClassifierService,   // <-- must become `any IntentClassifying`
        ...
    )
}
```

The entire orchestration body (slot filling, confirmation, date-time resolution, ~320 lines) is language-agnostic. **Only the `classifier` property type and the `init` parameter type change.** Zero logic changes.

### 1.4 LiveTranscriptionViewModel.swift — Hardcoded construction

File: `STT/ViewModels/LiveTranscriptionViewModel.swift`, method `activate()` around line 95:

```swift
// CURRENT:
if nlu == nil {
    let ic = IntentClassifierService()   // hardcoded concrete type
    nlu = NLUEngine(classifier: ic)
    Task(priority: .userInitiated) { await ic.warmUp() }
}
```

After the refactor, `nlu` becomes `any ConversationEngine` and is created via an injected factory. The `activate()` call becomes:

```swift
if nlu == nil {
    let engine = factory.makeEngine()    // factory injected at init
    nlu = engine
    Task(priority: .userInitiated) { await engine.warmUp() }
}
```

The `nlu` property declaration changes from `NLUEngine?` to `(any ConversationEngine)?`.

### 1.5 PVAViewModel.swift — No variant threading

File: `STT/ViewModels/PVAViewModel.swift`

`init()` takes no arguments. After the change it must accept `variant: NLUVariant` and create the appropriate factory:

```swift
// CURRENT:
init() {
    let c = TranscriptionCoordinator()
    self.coordinator = c
    self.liveViewModel = LiveTranscriptionViewModel(coordinator: c)
}

// AFTER:
init(variant: NLUVariant) {
    let c = TranscriptionCoordinator()
    self.coordinator = c
    let factory = NLUEngineFactoryProvider.make(for: variant)
    self.liveViewModel = LiveTranscriptionViewModel(coordinator: c, factory: factory)
}
```

### 1.6 STTTestView.swift — No Picker

File: `STT/Views/STTTestView.swift`

The PVA CTA button currently:
```swift
Button {
    pvaViewModel = PVAViewModel()    // no variant
} label: { ... }
```

Needs a `Picker` above the CTA and variant threading into `PVAViewModel(variant:)`.

### 1.7 NLU/ directory — Missing files

Files that do NOT yet exist and must be created:

| File | What it contains |
|------|-----------------|
| `STT/STT/Services/NLU/NLUVariant.swift` | `enum NLUVariant` |
| `STT/STT/Services/NLU/NLUProtocols.swift` | `IntentClassifying`, `ConversationEngine`, `NLUEngineFactory` protocols |
| `STT/STT/Services/NLU/TFIDFLogisticScorer.swift` | Shared TF-IDF + temperature-softmax value type |
| `STT/STT/Services/NLU/Multilingual/MultilingualIntentClassifierService.swift` | New classifier |
| `STT/STT/Services/NLU/Factory/NLUEngineFactoryProvider.swift` | English + Multilingual factory implementations |

### 1.8 Tests — Fixtures present, model resources not yet wired into test target

`STTTests/Resources/coreml_golden_fixtures.json` — present (359 KB).  
`STTTests/IntentClassifierCoreMLParityTests.swift` — present and auto-skips any model whose resources aren't bundled.  

The multilingual model artifacts (`IntentClassifier_multilingual.mlpackage` + `multilingual_intent_classifier_weights.json`) are in the **app target** resources but not yet added to the **STTTests target** in the Xcode project. The agent must add them to `STT.xcodeproj/project.pbxproj` under the test target membership.

---

## 2. Architecture — What to Build

### 2.1 Protocol layer (`NLUProtocols.swift`)

```swift
// MARK: - IntentClassifying
/// Contract every Stage-2 classifier must satisfy.
/// Both IntentClassifierService (English) and
/// MultilingualIntentClassifierService conform to this.
public protocol IntentClassifying: Actor {
    func classifyAsync(_ text: String) async -> ClassificationResult
    func genaiURL(for text: String) -> URL
    func warmUp() async
    func loadStage3() async
    func releaseStage3() async
}

// MARK: - ConversationEngine
/// Contract the ViewModel depends on — never names a concrete engine.
public protocol ConversationEngine: Actor {
    func handle(_ text: String) async -> NLUResponse
    func reset() async
    var isCollecting: Bool { get async }
    func loadStage3() async
    func releaseStage3() async
    func warmUp() async
}

// MARK: - NLUEngineFactory
/// Creates a ConversationEngine for a given variant.
/// The only place that names concrete types.
public protocol NLUEngineFactory {
    func makeEngine() -> any ConversationEngine
}
```

**Why `reset()` is `async`:** `NLUEngine.reset()` currently calls `session.resetAll()` which is synchronous, but the method must be `async` on the protocol because it runs on the actor's executor. The conformance body stays synchronous — `async` on an actor method just means callers must `await` it.

### 2.2 NLUVariant (`NLUVariant.swift`)

```swift
public enum NLUVariant: String, CaseIterable, Identifiable {
    case english      = "english"
    case multilingual = "multilingual"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english:      return "English"
        case .multilingual: return "Multilingual"
        }
    }
}
```

### 2.3 Shared scorer (`TFIDFLogisticScorer.swift`)

This is the math extracted from `IntentClassifierService` that both classifiers use. It is a `struct` (value type), not an actor. It is stateless after construction.

```swift
/// Encapsulates: tokenize → sublinear TF-IDF → L2-normalize → CoreML logits
/// → softmax(logits / T) → argmax label, 0.70 gate.
///
/// Both IntentClassifierService and MultilingualIntentClassifierService use this.
/// Each service is responsible only for loading resources and wiring CoreML.
public struct TFIDFLogisticScorer {
    public let labels: [String]
    public let vocab: [String: Int]
    public let idf: [Double]
    public let temperature: Double
    public let confThreshold: Double

    public func score(text: String, model: MLModel?) -> (label: String, confidence: Double, logits: [Double]) { ... }
    public func tokenize(_ text: String) -> [String] { ... }      // same as current private func
    public func tfidfVector(for text: String) -> [Double] { ... } // same as current private func
    public func softmaxScaled(_ logits: [Double]) -> [Double] { ... }
    public func l2Normalize(_ vec: [Double]) -> [Double] { ... }
}
```

`IntentClassifierService` constructs a `TFIDFLogisticScorer` from the parsed JSON and delegates `tfidfVector`, `softmaxScaled`, `l2Normalize` to it. The per-actor state (`logRegWeights`, `coreMLModel`) stays in the service.

### 2.4 Conform existing types

**`IntentClassifierService`:** add `: IntentClassifying` after `public actor IntentClassifierService`. All five required methods already exist with the right signatures. No logic change.

**`NLUEngine`:** 
- Change `private let classifier: IntentClassifierService` → `private let classifier: any IntentClassifying`
- Change `init(classifier: IntentClassifierService, ...)` → `init(classifier: any IntentClassifying, ...)`
- Add `: ConversationEngine` conformance. Add `warmUp()` method that delegates to `classifier.warmUp()`.
- `reset()` already exists but is synchronous — must be marked `async` (body unchanged, actors allow sync body in async method).
- All other logic: unchanged.

### 2.5 MultilingualIntentClassifierService

New file: `STT/STT/Services/NLU/Multilingual/MultilingualIntentClassifierService.swift`

Conforms to `IntentClassifying`. Mirrors `IntentClassifierService` structure but:

1. **Resource loading** — tries `.mlmodelc` then `.mlpackage` for the multilingual model. If `Multilingual/` is a folder reference (blue in Xcode), pass `subdirectory: "Multilingual"` to `Bundle.main.url`.

```swift
// Try compiled form first (Xcode compiles .mlpackage → .mlmodelc at build time)
let intentURL =
    Bundle.main.url(forResource: "IntentClassifier_multilingual",
                    withExtension: "mlmodelc",
                    subdirectory: multilingualSubdir)   // nil or "Multilingual" per Xcode config
    ?? Bundle.main.url(forResource: "IntentClassifier_multilingual",
                       withExtension: "mlpackage",
                       subdirectory: multilingualSubdir)

let jsonURL = Bundle.main.url(forResource: "multilingual_intent_classifier_weights",
                              withExtension: "json",
                              subdirectory: multilingualSubdir)
```

2. **Scoring** — uses `TFIDFLogisticScorer` (shared). No duplication of tokenize/tfidf/softmax.

3. **Stage 3** — reuses `SemanticEmbedder` + `SemanticClassifier` with the same English artifacts (`MiniLMEmbedder.mlpackage`, `semantic_head.json`). No changes to those types.

4. **`genaiURL(for:)`** — same implementation as English (delegates to `genaiBaseURL` from weights JSON).

5. **`fatalError` scope** — do NOT `fatalError` if the multilingual model is missing. Return a `.failure`-style graceful degradation instead (unlike English which has been in the app longer and can assert). Log an `os.log` error and degrade to JSON-weights-only fallback.

### 2.6 Factory (`NLUEngineFactoryProvider.swift`)

```swift
/// Returns the appropriate factory for a NLUVariant.
public enum NLUEngineFactoryProvider {
    public static func make(for variant: NLUVariant) -> any NLUEngineFactory {
        switch variant {
        case .english:      return EnglishNLUEngineFactory()
        case .multilingual: return MultilingualNLUEngineFactory()
        }
    }
}

public struct EnglishNLUEngineFactory: NLUEngineFactory {
    public func makeEngine() -> any ConversationEngine {
        let classifier = IntentClassifierService()
        return NLUEngine(classifier: classifier)
    }
}

public struct MultilingualNLUEngineFactory: NLUEngineFactory {
    public func makeEngine() -> any ConversationEngine {
        let classifier = MultilingualIntentClassifierService()
        return NLUEngine(classifier: classifier)
    }
}
```

The factory is the **only** place that names `IntentClassifierService` and `MultilingualIntentClassifierService` directly. `PVAViewModel`, `LiveTranscriptionViewModel`, and `NLUEngine` see only protocols.

### 2.7 ViewModel changes

**`LiveTranscriptionViewModel`:**
- Add `private let factory: any NLUEngineFactory` stored property
- Change `init(coordinator:)` → `init(coordinator:, factory:)`
- Change `@ObservationIgnored private var nlu: NLUEngine?` → `@ObservationIgnored private var nlu: (any ConversationEngine)?`
- In `activate()`: replace `IntentClassifierService()` + `NLUEngine(classifier:)` with `factory.makeEngine()`
- All method calls on `nlu` (`handle`, `reset`, `loadStage3`, `releaseStage3`) already match the `ConversationEngine` protocol — no further changes
- `warmUp()` call in `activate()`: call `engine.warmUp()` on the created engine (store engine locally before assigning to `nlu`)

**`PVAViewModel`:**
- Add `init(variant: NLUVariant)` — creates factory via `NLUEngineFactoryProvider.make(for:)`, passes to `LiveTranscriptionViewModel`
- `startSession()` body unchanged: calls `liveViewModel.activate()`, sets `stage2Status = .ready`
- `deinit` log unchanged

### 2.8 UI — STTTestView

```swift
// Add inside STTTestView:
@AppStorage("selectedNLUVariant") private var variant: NLUVariant = .english

// In pvaLauncher, above the Button:
Picker("NLU Variant", selection: $variant) {
    ForEach(NLUVariant.allCases) { v in
        Text(v.displayName).tag(v)
    }
}
.pickerStyle(.segmented)
.padding(.horizontal, 32)
.onChange(of: variant) { _, _ in
    // Full teardown before switching
    if pvaViewModel != nil {
        pvaViewModel?.teardown()
        pvaViewModel = nil
    }
}

// Change the Button action:
Button {
    pvaViewModel = PVAViewModel(variant: variant)
} label: { ... }
```

**`@AppStorage` for `NLUVariant`:** `AppStorage` requires the type to be `RawRepresentable` with `RawValue == String`. `NLUVariant` already has `rawValue: String` so this works directly.

---

## 3. File-by-File Change Spec

### Commit 1 — Cleanup: restore IntentClassifierService to English

**File:** `STT/STT/Services/IntentClassifierService.swift`

Change in `init()` — replace both resource-loading blocks:

```swift
// REMOVE these two lines:
let intentURL = Bundle.main.url(forResource: "IntentClassifier_multilingual", withExtension: "mlmodelc")
             ?? Bundle.main.url(forResource: "IntentClassifier_multilingual", withExtension: "mlpackage")

// REPLACE WITH:
let intentURL = Bundle.main.url(forResource: "IntentClassifier", withExtension: "mlmodelc")
             ?? Bundle.main.url(forResource: "IntentClassifier", withExtension: "mlpackage")
```

```swift
// REMOVE:
let jsonURL = Bundle.main.url(forResource: "multilingual_intent_classifier_weights",
                              withExtension: "json")
// REPLACE WITH:
let jsonURL = Bundle.main.url(forResource: "intent_classifier_weights",
                              withExtension: "json")
```

```swift
// REMOVE the fatalError message that references multilingual, REPLACE WITH:
fatalError("IntentClassifierService: intent_classifier_weights.json not found in bundle.")
```

All other code in this file is unchanged. The ~360 lines of TF-IDF, temperature-softmax, CoreML wiring, Stage 3 lifecycle all stay as-is.

**After this commit:** English pipeline works again. All existing tests pass.

---

### Commit 2 — Protocols: IntentClassifying, ConversationEngine, NLUEngineFactory

**New file:** `STT/STT/Services/NLU/NLUProtocols.swift`

Contains:
- `protocol IntentClassifying: Actor` (5 method requirements — listed above in §2.1)
- `protocol ConversationEngine: Actor` (5 method requirements — listed above in §2.1)
- `protocol NLUEngineFactory` (1 method requirement)

**New file:** `STT/STT/Services/NLU/NLUVariant.swift`

Contains `enum NLUVariant` as specified in §2.2.

---

### Commit 3 — DIP NLUEngine + conform to ConversationEngine

**File:** `STT/STT/Services/NLU/NLUEngine.swift`

Changes (only these, nothing else):

1. Declaration line: `public actor NLUEngine {` → `public actor NLUEngine: ConversationEngine {`
2. Property: `private let classifier: IntentClassifierService` → `private let classifier: any IntentClassifying`
3. Init parameter: `classifier: IntentClassifierService` → `classifier: any IntentClassifying`
4. Add `warmUp()` method (required by `ConversationEngine`):
   ```swift
   public func warmUp() async {
       await classifier.warmUp()
   }
   ```
5. Change `public func reset()` to `public func reset() async` — body unchanged (`session.resetAll()`).

All orchestration logic (confirmation/slot-filling/new-intent/date-time) is **untouched**.

---

### Commit 4 — Conform IntentClassifierService to IntentClassifying

**File:** `STT/STT/Services/IntentClassifierService.swift`

Single change: declaration line:
```swift
// FROM:
public actor IntentClassifierService {
// TO:
public actor IntentClassifierService: IntentClassifying {
```

All five protocol method requirements (`classifyAsync`, `genaiURL`, `warmUp`, `loadStage3`, `releaseStage3`) already exist with correct signatures. No other changes.

---

### Commit 5 — Extract TFIDFLogisticScorer + implement MultilingualIntentClassifierService

**New file:** `STT/STT/Services/NLU/TFIDFLogisticScorer.swift`

Extracts from `IntentClassifierService`:
- `tokenize(_ text: String) -> [String]`
- `tfidfVector(for text: String) -> [Double]` (depends on vocab + idf)
- `l2Normalize(_ vec: [Double]) -> [Double]`
- `softmax(_ logits: [Double]) -> [Double]`
- `softmaxScaled(_ logits: [Double], temperature: Double) -> [Double]`

Make it a `public struct` initialized with `(vocab: [String: Int], idf: [Double], temperature: Double, confThreshold: Double, labels: [String])`.

**Update `IntentClassifierService`:** Replace the duplicated math private methods with calls to a `private let scorer: TFIDFLogisticScorer` property. Initialize `scorer` in `init()` after JSON parsing. No behavior change.

**New file:** `STT/STT/Services/NLU/Multilingual/MultilingualIntentClassifierService.swift`

Full implementation — see §2.5 above. Uses `TFIDFLogisticScorer`. Conforms to `IntentClassifying`. Loads from `Resources/Multilingual/`.

---

### Commit 6 — Factory

**New file:** `STT/STT/Services/NLU/Factory/NLUEngineFactoryProvider.swift`

Contains `NLUEngineFactoryProvider` enum + `EnglishNLUEngineFactory` + `MultilingualNLUEngineFactory` — see §2.6.

---

### Commit 7 — Thread factory through ViewModels

**File:** `STT/ViewModels/LiveTranscriptionViewModel.swift`

1. Add stored property: `private let factory: any NLUEngineFactory`
2. Change `init(coordinator:)` → `init(coordinator: TranscriptionCoordinator, factory: any NLUEngineFactory)`
3. Change `nlu` type from `NLUEngine?` to `(any ConversationEngine)?`
4. In `activate()`: replace the 3-line hardcoded block with factory call (see §2.7)
5. `nlu?.reset()` call in `clearResults()`: becomes `Task { [nlu] in await nlu?.reset() }` — already async-wrapped, `reset()` is now `async` on protocol, so await is needed. The existing wrapper already handles this.

**File:** `STT/ViewModels/PVAViewModel.swift`

1. Change `init()` → `init(variant: NLUVariant)` — see §2.7

---

### Commit 8 — UI: variant Picker + full teardown lifecycle

**File:** `STT/Views/STTTestView.swift`

1. Add `@AppStorage("selectedNLUVariant") private var variant: NLUVariant = .english`
2. Add segmented `Picker` in `pvaLauncher` view builder, above the CTA button
3. Add `.onChange(of: variant)` modifier on the Picker to teardown + nil `pvaViewModel`
4. Change Button action from `PVAViewModel()` to `PVAViewModel(variant: variant)`

---

### Commit 9 — Tests

**File:** `STTTests/IntentClassifierCoreMLParityTests.swift`

No code changes needed — the test is already generic over model name and auto-skips missing resources.

**Xcode project file:** `STT.xcodeproj/project.pbxproj`

Add `multilingual_intent_classifier_weights.json` and `IntentClassifier_multilingual.mlpackage` to the `STTTests` target's resources phase. (The test bundle lookup `Bundle(for: IntentClassifierCoreMLParityTests.self)` finds them only when they are in the test target.)

**New file:** `STTTests/NLUEngineFactoryTests.swift`

```swift
// Tests:
// 1. EnglishNLUEngineFactory creates a distinct engine per call
// 2. MultilingualNLUEngineFactory creates a distinct engine per call
// 3. Two calls produce two separate instances (not a singleton)
// 4. Releasing the last reference logs [Deinit] NLUEngine + [Deinit] IntentClassifierService
//    (or MultilingualIntentClassifierService) — verified via expectation on deinit.
```

---

## 4. Documented Follow-Up (Out of Scope)

The multilingual classifier shares the English `nlu_schema.json` and `nlu_entities.json`. This means:
- Slot prompts are English-language regardless of the user's input language
- Entity extraction patterns are English-only

This is a known limitation. A future iteration would:
1. Add per-language schema JSON files (e.g. `nlu_schema_fr.json`, `nlu_schema_de.json`)
2. Thread a `schemaURL: URL` parameter through `NLUEngineFactory` → `NLUEngine` init
3. `MultilingualNLUEngineFactory.makeEngine()` would pick the schema based on the device locale

Document this in `MultilingualIntentClassifierService.swift` with a `// TODO(multilingual-schema):` comment.

---

## 5. Xcode Group vs Folder Reference — Investigation Step

Before writing `MultilingualIntentClassifierService.init()`, check:

```bash
grep -A3 'Multilingual' STT.xcodeproj/project.pbxproj | head -30
```

If `lastKnownFileType = folder` or `sourceTree = "<group>"` with children referencing `Multilingual` as a folder reference (blue icon), then `Bundle.main.url(forResource:withExtension:subdirectory:)` must pass `subdirectory: "Multilingual"`.

If it is a Yellow Group (no folder reference), files are copied to the bundle root and `subdirectory` must be `nil`.

Define a constant in `MultilingualIntentClassifierService`:

```swift
// Set to "Multilingual" if Resources/Multilingual is a folder reference (blue in Xcode).
// Set to nil if it is a yellow group (files flatten into bundle root).
private static let resourceSubdirectory: String? = nil // CONFIRM before building
```

---

## 6. Acceptance Criteria Checklist

- [ ] `IntentClassifierService.init()` loads `IntentClassifier.mlpackage` + `intent_classifier_weights.json` (English only)
- [ ] `NLUEngine` holds `any IntentClassifying`, no other logic change
- [ ] `NLUEngine` conforms to `ConversationEngine`
- [ ] `IntentClassifierService` conforms to `IntentClassifying` (no logic change)
- [ ] `TFIDFLogisticScorer` struct extracts shared math; used by both classifiers
- [ ] `MultilingualIntentClassifierService` loads from `Resources/Multilingual/`, conforms to `IntentClassifying`
- [ ] `MultilingualIntentClassifierService` uses `softmax(logits / T)`; missing T → 1.0
- [ ] `NLUEngineFactoryProvider` is the only place that names concrete classifier types
- [ ] `LiveTranscriptionViewModel` stores `any ConversationEngine`, created via injected `NLUEngineFactory`
- [ ] `PVAViewModel.init(variant:)` builds the matching factory
- [ ] `STTTestView` Picker persists variant via `@AppStorage`; switching while active tears down (`pvaViewModel = nil`) before launching new session
- [ ] Teardown verified: switching variant logs `[Deinit] PVAViewModel`, `[Deinit] LiveTranscriptionViewModel`, `[Deinit] NLUEngine`, `[Deinit] IntentClassifierService` (or Multilingual variant)
- [ ] Stage 3 (`SemanticEmbedder`, `SemanticClassifier`) reused unchanged by both variants
- [ ] No `if variant` branches inside any service type
- [ ] No orchestration logic duplicated (single `NLUEngine` class serves both)
- [ ] `IntentClassifierCoreMLParityTests` passes for English; multilingual also passes once test-target resources are wired in
- [ ] Slot-prompt/entity English-only limitation documented with `// TODO(multilingual-schema):`

---

## 7. Commit Sequence

| # | Branch | Subject |
|---|--------|---------|
| 1 | `claude/coreml-temperature-ios` | `fix: restore IntentClassifierService to English resources` |
| 2 | `claude/coreml-temperature-ios` | `feat: add IntentClassifying, ConversationEngine, NLUEngineFactory protocols + NLUVariant enum` |
| 3 | `claude/coreml-temperature-ios` | `refactor: NLUEngine depends on any IntentClassifying, conforms to ConversationEngine` |
| 4 | `claude/coreml-temperature-ios` | `refactor: IntentClassifierService conforms to IntentClassifying (no logic change)` |
| 5 | `claude/coreml-temperature-ios` | `feat: extract TFIDFLogisticScorer + add MultilingualIntentClassifierService` |
| 6 | `claude/coreml-temperature-ios` | `feat: add NLUEngineFactoryProvider with English + Multilingual factory implementations` |
| 7 | `claude/coreml-temperature-ios` | `refactor: thread NLUEngineFactory through PVAViewModel + LiveTranscriptionViewModel` |
| 8 | `claude/coreml-temperature-ios` | `feat: add NLU variant Picker to STTTestView with full teardown on switch` |
| 9 | `claude/coreml-temperature-ios` | `test: wire multilingual resources into test target + add factory unit test` |

---

## 8. Routine Setup — What an Agent Needs to Execute This

### 8.1 Environment requirements

This work is **Swift + Xcode only**. It cannot be executed in a Linux environment. The agent must run on macOS with:
- Xcode 15+ (for `.mlprogram` / `mlpackage` support)
- Python 3.10+ (only for the one-time artifact regeneration step)
- Access to `akashrwt5/IntentClassifier` at branch `claude/coreml-export` (only for regenerating `.mlpackage`)

### 8.2 One-time artifact refresh (run before Commit 1)

```bash
# In IntentClassifier repo @ claude/coreml-export:
python multilingual/export_coreml_multilingual.py --model multilingual --fp16
python multilingual/test/test_coreml_multilingual.py --model multilingual --full

# Copy into STT:
cp -R multilingual/models/multilingual/IntentClassifier_multilingual.mlpackage \
       <STT>/STT/STT/Resources/Multilingual/
cp    multilingual/models/multilingual/multilingual_intent_classifier_weights.json \
       <STT>/STT/STT/Resources/Multilingual/
cp    multilingual/models/multilingual/multilingual_intent_labels.json \
       <STT>/STT/STT/Resources/Multilingual/
```

Verify sha256 of the two JSON files matches the source. If already matching, skip the copy.

### 8.3 Confirming the Xcode group type (run before writing MultilingualIntentClassifierService)

```bash
grep -A5 'Multilingual' STT.xcodeproj/project.pbxproj | head -40
```

Record the result and set `resourceSubdirectory` in `MultilingualIntentClassifierService` accordingly.

### 8.4 What NOT to do

- Do not push to `main` or any `feature/*` branch
- Do not create a PR unless explicitly requested
- Do not modify `IntentClassifier` repo
- Do not add `if variant` branches inside `IntentClassifierService`, `NLUEngine`, or `SemanticEmbedder`
- Do not copy-paste the `NLUEngine` orchestrator body — `NLUEngine` is a single class shared by both variants via injected classifier
- Do not remove `SemanticEmbedder`/`SemanticClassifier` — Stage 3 is reused unchanged
- Do not consume `classProbability` from the CoreML model output — always read `logits` and apply `softmax(logits / T)` in Swift

### 8.5 Git config

```bash
git config user.email noreply@anthropic.com
git config user.name "Claude"
```

### 8.6 Push after each commit

```bash
git push -u origin claude/coreml-temperature-ios
```

Retry up to 4 times with exponential backoff (2s, 4s, 8s, 16s) on network failure only.

---

## 9. Quick Reference — Files and Their Roles

```
STT/STT/
├── Services/
│   ├── IntentClassifierService.swift          ← English classifier (restore + conform to protocol)
│   ├── SemanticEmbedder.swift                 ← Stage 3 — DO NOT MODIFY
│   ├── SemanticClassifier.swift               ← Stage 3 — DO NOT MODIFY
│   ├── KeywordMatcher.swift                   ← Stage 1 — DO NOT MODIFY
│   └── NLU/
│       ├── NLUProtocols.swift                 ← NEW: IntentClassifying, ConversationEngine, NLUEngineFactory
│       ├── NLUVariant.swift                   ← NEW: enum NLUVariant
│       ├── TFIDFLogisticScorer.swift          ← NEW: shared math (extracted from IntentClassifierService)
│       ├── NLUEngine.swift                    ← MODIFY: any IntentClassifying, ConversationEngine conformance
│       ├── Multilingual/
│       │   └── MultilingualIntentClassifierService.swift  ← NEW
│       └── Factory/
│           └── NLUEngineFactoryProvider.swift ← NEW: English + Multilingual factories
├── Resources/
│   ├── IntentClassifier.mlpackage             ← English CoreML model — unchanged
│   ├── intent_classifier_weights.json         ← English weights — unchanged
│   ├── MiniLMEmbedder.mlpackage               ← Stage 3 shared — unchanged
│   ├── SemanticHead.mlpackage                 ← Stage 3 shared — unchanged
│   ├── semantic_head.json                     ← Stage 3 shared — unchanged
│   ├── minilm-vocab.txt                       ← Stage 3 shared — unchanged
│   ├── nlu_schema.json                        ← Shared (English prompts — follow-up scope)
│   ├── nlu_entities.json                      ← Shared (English patterns — follow-up scope)
│   └── Multilingual/
│       ├── IntentClassifier_multilingual.mlpackage       ← Vendored multilingual CoreML
│       ├── multilingual_intent_classifier_weights.json   ← Vendored weights
│       └── multilingual_intent_labels.json               ← Vendored labels
STT/ViewModels/
│   ├── PVAViewModel.swift                     ← MODIFY: init(variant:), owns factory
│   └── LiveTranscriptionViewModel.swift       ← MODIFY: factory injection, any ConversationEngine
STT/Views/
│   └── STTTestView.swift                      ← MODIFY: Picker, @AppStorage, teardown logic
STTTests/
│   ├── IntentClassifierCoreMLParityTests.swift ← Wire multilingual resources into test target (pbxproj)
│   └── NLUEngineFactoryTests.swift            ← NEW: factory unit test
```
