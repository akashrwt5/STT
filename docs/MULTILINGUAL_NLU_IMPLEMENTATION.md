# Multilingual NLU Pipeline — Implementation Plan

**Branch:** `claude/beautiful-clarke-p441d4`  
**Repo:** `akashrwt5/STT`  
**Audited at:** commit `88b5215` (branch HEAD at time of analysis)

---

## 0. Agent Role & Code Standards

### Who you are

You are a Senior iOS / Swift engineer with 8+ years of production experience. Your specialisations are on-device ML inference with Core ML, Swift Concurrency (actors), and SwiftUI. You write code that survives senior review with zero questions — every design decision you make is the single best option available, and you know *why* before you write the first line.

### Non-negotiable standards

| Standard | Rule |
|----------|------|
| **Thread safety** | Use `actor` for all mutable service state. Never `@unchecked Sendable`. Never manual locks. Actor isolation is the Swift-concurrency-approved replacement for both. |
| **Dependency direction** | High-level modules (ViewModel, Engine) depend on abstractions (protocols), never on concrete types. Concrete types are named only inside factories. This is Dependency Inversion Principle. |
| **Branching over types** | Never add `if variant == .multilingual` inside a service or engine. Variant-specific behaviour belongs in variant-specific types selected at construction time. Adding a third variant later must be a new type + one new factory case — zero edits to existing code. |
| **Duplication** | The TF-IDF → L2-normalise → softmax(logits/T) math is written once in `TFIDFLogisticScorer`. Both classifiers call it. Copy-pasting 80 lines of math is not acceptable. |
| **CoreML contract** | Always read the `logits` output and apply `softmax(logits / T)` in Swift. Never consume `classProbability` — that output is softmax at T=1 and breaks the calibration contract. FLOAT32 input vector always (CoreML rejects dtype mismatches silently by falling back to the JSON path). |
| **Resource fallback** | Missing temperature key → T = 1.0 (plain softmax). Missing CoreML model → JSON-weights fallback. The app must never crash due to a missing optional resource; it degrades gracefully with an `os.log` error. |
| **Memory lifecycle** | Stage 3 (MiniLM) is loaded on demand and released on demand. Releasing the top object (PVAViewModel) must tear down the entire pipeline. Verified via `[Deinit]` log chain. |
| **Logging** | `os.log` with structured interpolation for all service-layer events. `print("[Deinit] ...")` is acceptable for deinit confirmation only. No bare `print` elsewhere. |
| **No dead code** | Do not leave `// TODO` in production paths. Only `// TODO(multilingual-schema):` for the documented out-of-scope follow-up is allowed. |
| **MARK sections** | Every file uses `// MARK: -` sections matching the surrounding codebase style. |
| **Comments** | Explain WHY, not WHAT. Variable names explain what. Comments explain non-obvious constraints, invariants, and tradeoffs. |

### Architectural decisions — pre-justified

**Why `protocol IntentClassifying: Actor` instead of a class hierarchy?**  
Actors cannot inherit from other actors in Swift. A base-class approach would require `class` + manual `nonisolated` + locks — exactly what actors replace. Protocol conformance is the idiomatic Swift Concurrency composition model. It also allows the test suite to inject a mock conformer with zero impact on production code.

**Why `any IntentClassifying` (existential) instead of a generic `<C: IntentClassifying>`?**  
`NLUEngine` stores the classifier as a long-lived property (not a transient call). Existentials (`any`) are the correct tool for stored heterogeneous protocol values. Generics are correct for functions/algorithms that operate uniformly over a type — not for ownership. Using a generic here would force the caller to specify the concrete type at the `NLUEngine` call site, defeating the entire purpose of the abstraction.

**Why is `TFIDFLogisticScorer` a `struct` (value type) and not an actor or class?**  
It is stateless after construction. All its methods are pure functions over immutable inputs (vocab, idf, temperature, labels). Value types are the correct tool for stateless computation — they have no identity, cannot be mutated, and require no synchronisation. Making it an actor would add unnecessary executor hops for work that is already off-main because it runs inside actor methods.

**Why does `MultilingualIntentClassifierService` live at `STT/STT/Services/` and not in a `NLU/Multilingual/` subfolder?**  
`IntentClassifierService.swift` lives at `STT/STT/Services/IntentClassifierService.swift`. A classifier is a service, not an NLU orchestration type. The `NLU/` subfolder contains orchestration and schema types: `NLUEngine`, `EntityExtractor`, `NLUSchema`, `NLUResponse`, `ConversationSpeaker`. The two classifiers are peers — same directory level, same conceptual layer. Placing the multilingual classifier in a subfolder would imply it has lower status or different architectural role, which is false.

**Why `NLUEngineFactoryProvider` and not a `switch` inside the ViewModel?**  
The ViewModel must not know concrete types. If it contained `switch variant { case .english: IntentClassifierService() }` it would have a hard dependency on both concrete classifiers, making it impossible to test in isolation and requiring edits every time a variant is added. The factory pattern moves that coupling to a single dedicated type. ViewModel depends only on `NLUEngineFactory`.

**Why does `NLUEngine.reset()` become `async` even though its body is synchronous?**  
`NLUEngine` is an actor. A caller on the `@MainActor` (ViewModel) must `await` any call into an actor method regardless of whether the body does async work. The protocol `ConversationEngine` declares `reset() async` so that callers uniformly `await` it. The conformance body (`session.resetAll()`) remains synchronous — Swift allows a synchronous body to satisfy an `async` protocol requirement.

**Why `@AppStorage` for `NLUVariant` in the View?**  
`NLUVariant` has `RawValue == String` so it satisfies `AppStorage`'s `RawRepresentable` requirement directly. Persisting the selected variant means the user's choice survives app restarts without any additional storage infrastructure. The alternative (`UserDefaults` manual read/write) is more code for the same outcome.

**Why does switching variant tear down the existing session before starting the new one?**  
The entire pipeline (TranscriptionCoordinator → LiveTranscriptionViewModel → NLUEngine → classifier) holds Core ML model handles and audio session resources. Running two pipelines simultaneously would double ANE memory and risk audio session conflicts. Setting `pvaViewModel = nil` releases the entire chain (verified by the deinit log sequence) before the new one is constructed.

---

## 1. Current State — What the Branch Actually Contains

> Every finding below is from reading the actual files at commit `88b5215`.

### 1.1 Resources — Multilingual artifacts are present

`STT/STT/Resources/Multilingual/` contains:

| File | Size | Status |
|------|------|--------|
| `IntentClassifier_multilingual.mlpackage` | (dir) | Present — regenerate from exporter to guarantee FP16 mlprogram with temperature metadata |
| `multilingual_intent_classifier_weights.json` | 8.6 MB | Present — byte-verify sha256 against IntentClassifier repo source |
| `multilingual_intent_labels.json` | 1.3 KB | Present |

**Critical — Xcode group vs folder reference:** The `Multilingual` entry is a plain `dir` in the GitHub tree. This is ambiguous: it could be a Yellow Group (files flatten to bundle root) or a Blue Folder Reference (files land under `Multilingual/` in the bundle). This determines whether `Bundle.main.url(forResource:withExtension:subdirectory:)` needs `subdirectory: "Multilingual"`. **Must be confirmed before writing `MultilingualIntentClassifierService.init()`** using the command in §8.3.

### 1.2 IntentClassifierService.swift — CONTAMINATED

File: `STT/STT/Services/IntentClassifierService.swift`

A prior "temp multilingual push" (commit `88b5215`) mutated `init()` to load multilingual resources. The English pipeline currently loads the wrong model at runtime.

```swift
// CURRENTLY WRONG in init():
let intentURL = Bundle.main.url(forResource: "IntentClassifier_multilingual", withExtension: "mlmodelc")
             ?? Bundle.main.url(forResource: "IntentClassifier_multilingual", withExtension: "mlpackage")
let jsonURL = Bundle.main.url(forResource: "multilingual_intent_classifier_weights", withExtension: "json")
```

Must be restored to:

```swift
// CORRECT — English resources:
let intentURL = Bundle.main.url(forResource: "IntentClassifier", withExtension: "mlmodelc")
             ?? Bundle.main.url(forResource: "IntentClassifier", withExtension: "mlpackage")
let jsonURL = Bundle.main.url(forResource: "intent_classifier_weights", withExtension: "json")
```

The `fatalError` message must also reference `intent_classifier_weights.json`. No other logic changes — the 360-line body (TF-IDF, temperature-softmax, CoreML wiring, Stage 3 lifecycle) is correct and stays as-is.

### 1.3 NLUEngine.swift — Concrete dependency

File: `STT/STT/Services/NLU/NLUEngine.swift`

```swift
// CURRENT:
public actor NLUEngine {
    private let classifier: IntentClassifierService  // ← concrete type
    public init(classifier: IntentClassifierService, ...) { ... }
}
```

Only the property type and init parameter type change. The entire ~320-line orchestration body (confirmation → slot-filling → new-intent, date-time resolution, carrier-phrase stripping) is language-agnostic and is **not touched**.

### 1.4 LiveTranscriptionViewModel.swift — Hardcoded construction

File: `STT/ViewModels/LiveTranscriptionViewModel.swift`, `activate()` ~line 95:

```swift
// CURRENT:
if nlu == nil {
    let ic = IntentClassifierService()    // hardcoded concrete type
    nlu = NLUEngine(classifier: ic)
    Task(priority: .userInitiated) { await ic.warmUp() }
}
```

After the change `nlu` is `(any ConversationEngine)?`, built via an injected factory.

### 1.5 PVAViewModel.swift — No variant threading

File: `STT/ViewModels/PVAViewModel.swift` — `init()` takes no arguments.

### 1.6 STTTestView.swift — No Picker

File: `STT/Views/STTTestView.swift` — CTA calls `PVAViewModel()` with no variant.

### 1.7 Missing files

| File | Status |
|------|--------|
| `STT/STT/Services/MultilingualIntentClassifierService.swift` | Does not exist |
| `STT/STT/Services/TFIDFLogisticScorer.swift` | Does not exist |
| `STT/STT/Services/NLU/NLUProtocols.swift` | Does not exist |
| `STT/STT/Services/NLU/NLUVariant.swift` | Does not exist |
| `STT/STT/Services/NLU/NLUEngineFactoryProvider.swift` | Does not exist |

### 1.8 Test target — multilingual resources not wired in

`STTTests/Resources/coreml_golden_fixtures.json` — present (359 KB).  
`STTTests/IntentClassifierCoreMLParityTests.swift` — present, auto-skips any model whose resources are absent from the test bundle.  
Multilingual model artifacts are in the **app target** only. They must also be added to the **STTTests target** in `STT.xcodeproj/project.pbxproj`.

---

## 2. Final File Layout

```
STT/STT/
├── Services/
│   ├── IntentClassifierService.swift              MODIFY  restore English + add : IntentClassifying
│   ├── MultilingualIntentClassifierService.swift  NEW     peer of IntentClassifierService
│   ├── TFIDFLogisticScorer.swift                  NEW     shared math (Services/ level, used by both classifiers)
│   ├── KeywordMatcher.swift                                DO NOT MODIFY
│   ├── SemanticEmbedder.swift                              DO NOT MODIFY  (Stage 3, shared by both)
│   ├── SemanticClassifier.swift                            DO NOT MODIFY  (Stage 3, shared by both)
│   ├── MemoryProbe.swift                                   DO NOT MODIFY
│   └── NLU/
│       ├── NLUProtocols.swift                     NEW     IntentClassifying, ConversationEngine, NLUEngineFactory
│       ├── NLUVariant.swift                       NEW     enum NLUVariant
│       ├── NLUEngineFactoryProvider.swift         NEW     English + Multilingual factory implementations
│       ├── NLUEngine.swift                        MODIFY  any IntentClassifying + ConversationEngine conformance
│       ├── ConversationSpeaker.swift                       DO NOT MODIFY
│       ├── EntityExtractor.swift                           DO NOT MODIFY
│       ├── NLUContext.swift                                DO NOT MODIFY
│       ├── NLUResponse.swift                               DO NOT MODIFY
│       ├── NLUSchema.swift                                 DO NOT MODIFY
│       └── SlotFormatting.swift                            DO NOT MODIFY
├── Resources/
│   ├── IntentClassifier.mlpackage                         English CoreML model — unchanged
│   ├── intent_classifier_weights.json                     English weights — unchanged
│   ├── MiniLMEmbedder.mlpackage                           Stage 3 shared — unchanged
│   ├── SemanticHead.mlpackage                             Stage 3 shared — unchanged
│   ├── semantic_head.json                                 Stage 3 shared — unchanged
│   ├── minilm-vocab.txt                                   Stage 3 shared — unchanged
│   ├── nlu_schema.json                                    Shared (English slot prompts — see §4)
│   ├── nlu_entities.json                                  Shared (English entity patterns — see §4)
│   └── Multilingual/
│       ├── IntentClassifier_multilingual.mlpackage        Vendored multilingual CoreML
│       ├── multilingual_intent_classifier_weights.json    Vendored weights
│       └── multilingual_intent_labels.json               Vendored labels
STT/ViewModels/
│   ├── PVAViewModel.swift                         MODIFY  init(variant:) + owns factory
│   └── LiveTranscriptionViewModel.swift           MODIFY  factory injection + any ConversationEngine
STT/Views/
│   └── STTTestView.swift                          MODIFY  Picker + @AppStorage + teardown on switch
STTTests/
│   ├── IntentClassifierCoreMLParityTests.swift            NO CODE CHANGE — wire resources into test target
│   └── NLUEngineFactoryTests.swift                NEW     factory unit test
```

**Why `MultilingualIntentClassifierService` is at `Services/` and not `Services/NLU/`:**  
Classifiers are services, not orchestration types. `IntentClassifierService` lives at `Services/`. Its multilingual peer belongs at the same level — same architectural layer, same conceptual role. `Services/NLU/` contains orchestration types: `NLUEngine`, `EntityExtractor`, `NLUSchema`, `NLUResponse`. Placing the classifier inside `NLU/` would incorrectly imply it is an orchestration type.

**Why `TFIDFLogisticScorer` is at `Services/` and not `Services/NLU/`:**  
It is consumed by `IntentClassifierService` and `MultilingualIntentClassifierService`, both of which live at `Services/`. Placing their shared dependency one level above would invert the natural dependency direction. Co-location at `Services/` is correct.

---

## 3. Architecture

### 3.1 Protocol layer — `NLUProtocols.swift`

```swift
import Foundation

// MARK: - IntentClassifying

/// Contract every Stage-2 classifier must satisfy.
///
/// Declared as Actor so callers must `await` every method — the actor provides
/// both off-main execution and serialisation of mutable state (coreMLModel,
/// logRegWeights, semanticEmbedder) without locks or @unchecked Sendable.
///
/// Both IntentClassifierService (English) and MultilingualIntentClassifierService
/// conform to this. NLUEngine depends only on this protocol — it never names
/// a concrete classifier type.
public protocol IntentClassifying: Actor {
    /// Full 3-stage async classification. Returns stage, confidence, and breakdown.
    func classifyAsync(_ text: String) async -> ClassificationResult
    /// GenAI fallback URL for an unrecognised query.
    func genaiURL(for text: String) -> URL
    /// Pre-warms CoreML graphs (ANE specialisation) in the background.
    func warmUp() async
    /// Loads Stage 3 (MiniLM embedder + semantic head) and triggers ANE compile.
    func loadStage3() async
    /// Releases Stage 3 refs. Stage 3 is skipped on future classifications.
    func releaseStage3() async
}

// MARK: - ConversationEngine

/// Contract the ViewModel depends on.
///
/// The ViewModel stores `any ConversationEngine` and never names NLUEngine
/// directly. This allows the factory to return any conforming actor without
/// the ViewModel needing to change.
public protocol ConversationEngine: Actor {
    /// Processes one user utterance and returns the next conversational step.
    func handle(_ text: String) async -> NLUResponse
    /// Abandons any in-progress conversation (slot filling / confirmation).
    func reset() async
    /// True when the engine is mid-conversation and the next utterance is an answer.
    var isCollecting: Bool { get async }
    /// Loads Stage 3 on the underlying classifier.
    func loadStage3() async
    /// Releases Stage 3 on the underlying classifier.
    func releaseStage3() async
    /// Pre-warms the underlying classifier's CoreML graphs.
    func warmUp() async
}

// MARK: - NLUEngineFactory

/// Creates a fully configured ConversationEngine for a given variant.
///
/// This is the only place in the codebase that names concrete classifier types.
/// Adding a third NLU variant requires a new conforming struct here and one
/// new case in NLUEngineFactoryProvider.make(for:) — zero edits to
/// NLUEngine, LiveTranscriptionViewModel, or PVAViewModel.
public protocol NLUEngineFactory {
    func makeEngine() -> any ConversationEngine
}
```

### 3.2 NLUVariant — `NLUVariant.swift`

```swift
import Foundation

/// Selectable NLU pipeline variant.
///
/// RawValue is String so @AppStorage can persist the selection directly
/// without a custom RawRepresentable implementation.
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

### 3.3 TFIDFLogisticScorer — `TFIDFLogisticScorer.swift`

```swift
import CoreML
import Foundation

/// Stateless TF-IDF → L2-normalise → CoreML logits → softmax(logits/T) scorer.
///
/// A value type (struct) because it is stateless after construction: all methods
/// are pure functions over immutable inputs. Both IntentClassifierService and
/// MultilingualIntentClassifierService hold one instance; neither duplicates
/// the math.
///
/// Device confidence contract (invariant):
///   confidence = softmax(logits / temperature)[argmax]
///   temperature is read from the weights JSON; missing key → T = 1.0.
///   The classProbability output of the .mlpackage is NEVER consumed — it is
///   softmax at T=1 and breaks calibration.
public struct TFIDFLogisticScorer {

    public let labels: [String]
    public let vocab: [String: Int]
    public let idf: [Double]
    /// Shipped per-model calibration scalar. T=1.0 degrades to plain softmax.
    public let temperature: Double
    /// Confidence gate. Predictions below this score fall through to Stage 3.
    public let confThreshold: Double

    public init(
        labels: [String],
        vocab: [String: Int],
        idf: [Double],
        temperature: Double,
        confThreshold: Double
    ) {
        self.labels       = labels
        self.vocab        = vocab
        self.idf          = idf
        self.temperature  = temperature > 0 ? temperature : 1.0
        self.confThreshold = confThreshold
    }

    // MARK: - CoreML input

    /// Builds a FLOAT32 MLMultiArray from the TF-IDF vector.
    ///
    /// The mlprogram exporter declares tfidf_vector as FLOAT32. CoreML rejects
    /// a dtype mismatch silently by refusing the prediction — always Float32.
    public func coreMLInput(for text: String) -> MLDictionaryFeatureProvider? {
        let vec = tfidfVector(for: text)
        let n = vec.count
        guard n > 0,
              let arr = try? MLMultiArray(shape: [n as NSNumber], dataType: .float32)
        else { return nil }
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<n { ptr[i] = Float(vec[i]) }
        return try? MLDictionaryFeatureProvider(dictionary: [
            "tfidf_vector": MLFeatureValue(multiArray: arr)
        ])
    }

    // MARK: - Vectorisation

    /// lowercase → split on non-alphanumerics → unigrams + adjacent bigrams.
    public func tokenize(_ text: String) -> [String] {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var tokens = words
        for i in words.indices.dropLast() { tokens.append(words[i] + " " + words[i + 1]) }
        return tokens
    }

    /// Sublinear TF-IDF over the pruned vocab, then L2-normalise.
    public func tfidfVector(for text: String) -> [Double] {
        var counts: [Int: Int] = [:]
        for tok in tokenize(text) {
            if let i = vocab[tok] { counts[i, default: 0] += 1 }
        }
        var vec = [Double](repeating: 0.0, count: idf.count)
        for (i, c) in counts { vec[i] = (1.0 + log(Double(c))) * idf[i] }
        return l2Normalize(vec)
    }

    // MARK: - Math

    public func l2Normalize(_ vec: [Double]) -> [Double] {
        let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vec }
        return vec.map { $0 / norm }
    }

    public func softmax(_ logits: [Double]) -> [Double] {
        guard !logits.isEmpty else { return [] }
        let mx = logits.max()!
        let exps = logits.map { exp($0 - mx) }
        let sum = exps.reduce(0, +)
        return sum == 0 ? logits.map { _ in 1.0 / Double(logits.count) } : exps.map { $0 / sum }
    }

    /// softmax(logits / T) — the device confidence contract.
    /// T > 0 is enforced at init; T ≤ 0 is treated as 1.0 defensively.
    public func softmaxScaled(_ logits: [Double]) -> [Double] {
        softmax(logits.map { $0 / temperature })
    }
}
```

### 3.4 IntentClassifierService — conformance only

Two changes to `STT/STT/Services/IntentClassifierService.swift`:

1. Declaration: `public actor IntentClassifierService {` → `public actor IntentClassifierService: IntentClassifying {`
2. Replace all five private math methods (`tokenize`, `tfidfVector`, `l2Normalize`, `softmax`, `softmaxScaled`) and the `coreMLInput` helper with calls to `private let scorer: TFIDFLogisticScorer`. Initialise `scorer` at the end of `init()` after JSON parsing. All call sites in `stage2Scores`, `tfidfLogits`, `coreMLInput` delegate to `scorer`.

All five `IntentClassifying` requirements (`classifyAsync`, `genaiURL`, `warmUp`, `loadStage3`, `releaseStage3`) are already implemented with matching signatures — conformance is satisfied without new code.

### 3.5 NLUEngine — dependency inversion only

Five changes to `STT/STT/Services/NLU/NLUEngine.swift`. Nothing else:

```swift
// 1. Add ConversationEngine conformance:
public actor NLUEngine: ConversationEngine {

// 2. Change property type:
private let classifier: any IntentClassifying

// 3. Change init parameter:
public init(
    schema: NLUSchema = .loadFromBundle(),
    classifier: any IntentClassifying,
    ...
)

// 4. Add warmUp() (required by ConversationEngine, delegates to classifier):
public func warmUp() async {
    await classifier.warmUp()
}

// 5. Mark reset() async (required by ConversationEngine; body is unchanged):
public func reset() async {
    session.resetAll()
}
```

The entire ~320-line orchestration body (confirmation → slot-filling → new-intent, date-time resolution, carrier-phrase stripping, interrupt threshold, `yesNo`, `extractAllSlots`, `advanceSlots`) is **not touched**.

### 3.6 MultilingualIntentClassifierService — new file

New file: `STT/STT/Services/MultilingualIntentClassifierService.swift`

Structure mirrors `IntentClassifierService` exactly. Key differences:

**Resource loading:**
```swift
// Confirm subdirectory value using: grep -A5 'Multilingual' STT.xcodeproj/project.pbxproj
// nil  → Yellow Group (files in bundle root)
// "Multilingual" → Blue Folder Reference (files under Multilingual/ in bundle)
private static let resourceSubdir: String? = nil  // SET AFTER CONFIRMING XCODE GROUP TYPE

init() {
    let intentURL =
        Bundle.main.url(forResource: "IntentClassifier_multilingual",
                        withExtension: "mlmodelc", subdirectory: Self.resourceSubdir)
        ?? Bundle.main.url(forResource: "IntentClassifier_multilingual",
                           withExtension: "mlpackage", subdirectory: Self.resourceSubdir)

    // Graceful degradation — do NOT fatalError on missing model.
    // The multilingual model is newer; if the bundle is stale, degrade to
    // JSON-weights-only path (tfidfLogits) rather than crashing.
    if let modelURL = intentURL {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        coreMLModel = try? MLModel(contentsOf: modelURL, configuration: config)
    } else {
        coreMLModel = nil
        logger.error("IntentClassifier_multilingual not found in bundle — Stage 2 will use JSON weights fallback")
    }

    let jsonURL = Bundle.main.url(
        forResource: "multilingual_intent_classifier_weights",
        withExtension: "json",
        subdirectory: Self.resourceSubdir
    )
    guard
        let url  = jsonURL,
        let data = try? Data(contentsOf: url),
        let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        // Weights JSON is required — without vocab + idf the vectoriser cannot run.
        // This is a build-time error (missing vendored resource), not a runtime one.
        fatalError("MultilingualIntentClassifierService: multilingual_intent_classifier_weights.json not found in bundle.")
    }
    // ... parse labels, vocab, idf, temperature, thresholds exactly as IntentClassifierService
    // ... construct scorer = TFIDFLogisticScorer(labels:vocab:idf:temperature:confThreshold:)
}
```

**Stage 3 reuse — no changes to SemanticEmbedder or SemanticClassifier:**
```swift
// loadStage3(), releaseStage3(), warmUp() — identical body to IntentClassifierService.
// SemanticEmbedder loads MiniLMEmbedder.mlpackage from the root Resources/ dir.
// semantic_head.json is also in root Resources/.
// No subdirectory needed for Stage 3 resources — they are English resources
// already correctly placed.
```

**Out-of-scope limitation — document inline:**
```swift
// TODO(multilingual-schema): slot prompts and entity extraction currently use
// the English nlu_schema.json and nlu_entities.json. True per-language
// slot-filling requires per-language schema files injected via the factory.
// Tracked as a follow-up; see docs/MULTILINGUAL_NLU_IMPLEMENTATION.md §4.
```

### 3.7 NLUEngineFactoryProvider — `NLU/NLUEngineFactoryProvider.swift`

```swift
import Foundation

// MARK: - Provider

/// Maps a NLUVariant to the appropriate factory.
///
/// This enum is the single point that names both concrete classifier types.
/// To add a third variant: add a case here and a new factory struct below.
/// No other file changes.
public enum NLUEngineFactoryProvider {
    public static func make(for variant: NLUVariant) -> any NLUEngineFactory {
        switch variant {
        case .english:      return EnglishNLUEngineFactory()
        case .multilingual: return MultilingualNLUEngineFactory()
        }
    }
}

// MARK: - English

public struct EnglishNLUEngineFactory: NLUEngineFactory {
    public func makeEngine() -> any ConversationEngine {
        NLUEngine(classifier: IntentClassifierService())
    }
}

// MARK: - Multilingual

public struct MultilingualNLUEngineFactory: NLUEngineFactory {
    public func makeEngine() -> any ConversationEngine {
        NLUEngine(classifier: MultilingualIntentClassifierService())
    }
}
```

### 3.8 LiveTranscriptionViewModel

Changes only:

```swift
// ADD stored property (after coordinator):
private let factory: any NLUEngineFactory

// CHANGE init signature:
public init(coordinator: TranscriptionCoordinator, factory: any NLUEngineFactory) {
    self.coordinator = coordinator
    self.factory = factory
    self.currentLocale = coordinator.currentLocale
}

// CHANGE nlu property type:
@ObservationIgnored private var nlu: (any ConversationEngine)?

// CHANGE activate() block:
if nlu == nil {
    let engine = factory.makeEngine()
    nlu = engine
    // warmUp is called on the engine (not on a separate classifier ref) because
    // ConversationEngine.warmUp() delegates to the classifier — one call site.
    Task(priority: .userInitiated) { await engine.warmUp() }
}

// CHANGE clearResults() nlu?.reset() call:
// reset() is now async on the protocol — the existing Task wrapper already handles this.
Task { [nlu] in await nlu?.reset() }
```

All other LiveTranscriptionViewModel code is unchanged.

### 3.9 PVAViewModel

```swift
// CHANGE init:
init(variant: NLUVariant) {
    let c = TranscriptionCoordinator()
    self.coordinator = c
    let factory = NLUEngineFactoryProvider.make(for: variant)
    self.liveViewModel = LiveTranscriptionViewModel(coordinator: c, factory: factory)
}
```

All other PVAViewModel code is unchanged (`startSession`, `teardown`, `deinit`, stage status properties).

### 3.10 STTTestView

```swift
// ADD property (with other @State properties at top of struct):
@AppStorage("selectedNLUVariant") private var variant: NLUVariant = .english

// ADD in pvaLauncher VStack, above the Button (between the label VStack and the Button):
Picker("NLU Variant", selection: $variant) {
    ForEach(NLUVariant.allCases) { v in
        Text(v.displayName).tag(v)
    }
}
.pickerStyle(.segmented)
.padding(.horizontal, 32)
// Full teardown on switch: nil-ing pvaViewModel releases the entire pipeline
// (PVAViewModel → TranscriptionCoordinator → LiveTranscriptionViewModel →
// NLUEngine → classifier → SemanticEmbedder) before the new one starts.
// Verified by the [Deinit] log chain in the Xcode console.
.onChange(of: variant) { _, _ in
    if pvaViewModel != nil {
        pvaViewModel?.teardown()
        pvaViewModel = nil
    }
}

// CHANGE Button action:
Button {
    pvaViewModel = PVAViewModel(variant: variant)
} label: { ... }
```

---

## 4. Documented Follow-Up (Out of Scope — Do Not Implement)

The multilingual classifier shares `nlu_schema.json` and `nlu_entities.json`. Consequences:
- Slot prompts are English regardless of input language
- Entity extraction patterns are English-only

This is a documented limitation, not a bug. Add `// TODO(multilingual-schema):` in `MultilingualIntentClassifierService.swift` and `MultilingualNLUEngineFactory.makeEngine()`. A future iteration injects a locale-appropriate schema URL through the factory.

---

## 5. Xcode Group Type Confirmation

Run this **before writing `MultilingualIntentClassifierService.init()`**:

```bash
grep -A5 'Multilingual' STT.xcodeproj/project.pbxproj | head -40
```

- If `lastKnownFileType = folder` or the entry is a folder reference: set `resourceSubdir = "Multilingual"`
- If it is a Yellow Group (child file refs, no folder type): set `resourceSubdir = nil`

---

## 6. Acceptance Criteria

- [ ] `IntentClassifierService.init()` loads `IntentClassifier` + `intent_classifier_weights.json` (English)
- [ ] `IntentClassifierService` conforms to `IntentClassifying` — no logic change
- [ ] `NLUEngine` holds `any IntentClassifying` — no logic change to orchestration body
- [ ] `NLUEngine` conforms to `ConversationEngine`
- [ ] `TFIDFLogisticScorer` is used by both classifiers — math not duplicated
- [ ] `MultilingualIntentClassifierService` is at `STT/STT/Services/` (peer of `IntentClassifierService`)
- [ ] `MultilingualIntentClassifierService` uses `softmax(logits/T)`; missing T → 1.0; missing model → graceful degradation (no crash)
- [ ] `NLUEngineFactoryProvider` is at `STT/STT/Services/NLU/` — only place that names concrete classifiers
- [ ] `LiveTranscriptionViewModel` stores `(any ConversationEngine)?`, built via injected factory
- [ ] `PVAViewModel.init(variant:)` builds the matching factory
- [ ] `STTTestView` Picker persists via `@AppStorage`; switching while active fully tears down before launching new session
- [ ] Full deinit chain confirmed in Xcode console: `[Deinit] PVAViewModel` → `[Deinit] LiveTranscriptionViewModel` → `[Deinit] NLUEngine` → `[Deinit] IntentClassifierService` (or Multilingual)
- [ ] Stage 3 (`SemanticEmbedder`, `SemanticClassifier`) unchanged — reused by both variants
- [ ] No `if variant` branches inside any service or engine type
- [ ] No orchestration logic duplicated — single `NLUEngine` class
- [ ] `IntentClassifierCoreMLParityTests` passes for English; multilingual passes once test-target resources wired
- [ ] `// TODO(multilingual-schema):` present in `MultilingualIntentClassifierService` and `MultilingualNLUEngineFactory`
- [ ] All files have `// MARK: -` sections matching surrounding codebase style
- [ ] Zero force-unwraps except in truly invariant cases (`fatalError` on missing required JSON)

---

## 7. Commit Sequence

| # | Commit message | Files changed |
|---|---------------|---------------|
| 1 | `fix: restore IntentClassifierService to English resources` | `IntentClassifierService.swift` |
| 2 | `feat: add NLUVariant, IntentClassifying, ConversationEngine, NLUEngineFactory protocols` | `NLUVariant.swift`, `NLUProtocols.swift` |
| 3 | `feat: extract TFIDFLogisticScorer; update IntentClassifierService to use it` | `TFIDFLogisticScorer.swift`, `IntentClassifierService.swift` |
| 4 | `refactor: NLUEngine depends on any IntentClassifying, conforms to ConversationEngine` | `NLUEngine.swift` |
| 5 | `refactor: IntentClassifierService conforms to IntentClassifying` | `IntentClassifierService.swift` |
| 6 | `feat: add MultilingualIntentClassifierService` | `MultilingualIntentClassifierService.swift` |
| 7 | `feat: add NLUEngineFactoryProvider with English and Multilingual factories` | `NLUEngineFactoryProvider.swift` |
| 8 | `refactor: thread NLUEngineFactory through PVAViewModel and LiveTranscriptionViewModel` | `PVAViewModel.swift`, `LiveTranscriptionViewModel.swift` |
| 9 | `feat: add NLU variant Picker to STTTestView with full teardown on switch` | `STTTestView.swift` |
| 10 | `test: wire multilingual resources into test target; add NLUEngineFactoryTests` | `project.pbxproj`, `NLUEngineFactoryTests.swift` |

---

## 8. Routine Setup — Everything the Agent Needs

### 8.1 Environment

- macOS only (Core ML, Xcode build, `.mlpackage` compilation)
- Xcode 15+ (mlprogram / FP16 support)
- Python 3.10+ (one-time artifact regeneration only)
- Git access to `akashrwt5/STT` branch `claude/beautiful-clarke-p441d4`
- Git access to `akashrwt5/IntentClassifier` branch `claude/sharp-ramanujan-p441d4` (artifact regeneration only)

### 8.2 One-time artifact refresh (before Commit 1)

```bash
# In IntentClassifier repo @ claude/sharp-ramanujan-p441d4:
python multilingual/export_coreml_multilingual.py --model multilingual --fp16
python multilingual/test/test_coreml_multilingual.py --model multilingual --full

# Verify JSON sha256 matches what is already in STT before overwriting:
sha256sum multilingual/models/multilingual/multilingual_intent_classifier_weights.json
sha256sum <STT>/STT/STT/Resources/Multilingual/multilingual_intent_classifier_weights.json

# Copy (overwrite .mlpackage regardless — it must be the FP16 mlprogram build):
cp -R multilingual/models/multilingual/IntentClassifier_multilingual.mlpackage \
       <STT>/STT/STT/Resources/Multilingual/
cp    multilingual/models/multilingual/multilingual_intent_classifier_weights.json \
       <STT>/STT/STT/Resources/Multilingual/
cp    multilingual/models/multilingual/multilingual_intent_labels.json \
       <STT>/STT/STT/Resources/Multilingual/
```

### 8.3 Confirm Xcode group type (before Commit 6)

```bash
grep -A5 'Multilingual' STT.xcodeproj/project.pbxproj | head -40
```

Set `MultilingualIntentClassifierService.resourceSubdir` accordingly.

### 8.4 Git config

```bash
git config user.email noreply@anthropic.com
git config user.name "Claude"
```

### 8.5 Push cadence

```bash
git push -u origin claude/beautiful-clarke-p441d4
```

Retry up to 4 times with exponential backoff (2 s, 4 s, 8 s, 16 s) on network failure only.

### 8.6 Hard constraints — never violate

- Push to `claude/beautiful-clarke-p441d4` only. Never `main`, never `feature/*`.
- Do not create a PR.
- Do not modify the IntentClassifier repo.
- Do not add `if variant` branches inside `IntentClassifierService`, `NLUEngine`, `SemanticEmbedder`, or `SemanticClassifier`.
- Do not copy-paste the NLUEngine orchestration body — it is shared by injecting a different classifier.
- Do not consume `classProbability` from any CoreML model output — always read `logits`, apply `softmax(logits/T)` in Swift.
- Do not remove or modify `SemanticEmbedder` or `SemanticClassifier` — Stage 3 is shared unchanged.
