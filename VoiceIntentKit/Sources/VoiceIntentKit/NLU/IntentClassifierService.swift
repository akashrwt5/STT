// IntentClassifierService.swift
// VoiceIntentKit
//
// 3-stage on-device intent classification pipeline. Bundle-driven: one actor
// serves every classifier variant, differing only in which `ClassifierBundle`
// (model file, weights JSON, calibration JSON) is passed at init. English and
// multilingual are two `ClassifierBundle` values, not two peer services.
//
// Stage 1 — Keyword rules   (KeywordMatcher)          sync, ~0 ms
// Stage 2 — TF-IDF + LogReg (CoreML intent model)     async, ~2 ms
// Stage 3 — Semantic rescue (MiniLM-L6-v2 via CoreML) async, ~8 ms
//
// Stage 2 primary: `<bundle.modelResourceName>.mlpackage` (compiled to
//   `.mlmodelc` by Xcode) exposing a `logits` output.
// Stage 2 fallback: `<bundle.weightsResourceName>.json` (pure-Swift
//   reimplementation, used automatically if the .mlpackage is absent or
//   CoreML prediction fails).
//
// Stage 3 activates only when Stage 2 returns low confidence or "Default
// Fallback Intent". Both SemanticEmbedder and SemanticClassifier return nil
// from their inits if their bundle artifacts are missing — Stage 3 is then
// skipped silently.

import CoreML
import Foundation
import os.log

// MARK: - Result type

public struct ClassificationResult: Sendable {
    public let label: String
    public let confidence: Double
    /// True when Stage 3 (MiniLM semantic rescue) produced this result.
    public let semanticRescue: Bool
    /// Per-stage detail for the eye-button debug panel.
    public let breakdown: ClassificationBreakdown
}

// MARK: - Service

// `actor` so its methods run on a serial executor off the main thread: callers
// reach it with `await classifier.classifyAsync(...)`, which hops off main for
// the call and back on return. The actor provides both off-main execution and
// serialisation for free.
public actor IntentClassifierService: IntentClassifying {

    // MARK: - Bundle descriptor

    private let bundle: ClassifierBundle

    // MARK: - Lifecycle

    deinit {
        print("[Deinit] IntentClassifierService(\(bundle.loggerCategory))")
    }

    // MARK: - Stage 1

    private let keywordMatcher = KeywordMatcher()

    // MARK: - Stage 2 — CoreML (primary)

    private let coreMLModel: MLModel?

    // MARK: - Stage 2 — JSON weights fallback

    // vocab + idf are loaded at init — they're needed to vectorize text for the
    // CoreML model's tfidf_vector input, so they can't be deferred.
    private let labels: [String]
    private let vocab: [String: Int]
    private let idf: [Double]

    /// LogReg coefficient matrix and intercepts — only materialised when CoreML
    /// prediction itself fails. Value-type so it can be nilled to reclaim memory.
    private struct LogRegWeights {
        let coef: [[Double]]
        let intercept: [Double]
    }

    /// Nil until the first CoreML prediction failure triggers the pure-Swift fallback.
    private var logRegWeights: LogRegWeights?
    /// Stored so the lazy loader can open the file without hitting Bundle.module again.
    private let weightsURL: URL?

    /// Temperature for the softmax(logits / T) confidence contract. Shipped in
    /// the weights JSON; a missing key ⇒ T = 1.0 (plain softmax), preserving
    /// backward compatibility with older bundles.
    private let temperature: Double

    /// Shared, stateless vectorisation + confidence math. Holds vocab/idf/
    /// labels/temperature; the TF-IDF → softmax(logits/T) math lives here.
    private let scorer: TFIDFLogisticScorer

    // MARK: - Stage 3

    // Both nil until `loadStage3()` is called (manual lifecycle for memory
    // control). When loaded, MiniLM weights + ANE specialization live here.
    private var semanticEmbedder: SemanticEmbedder?
    private var semanticClassifier: SemanticClassifier?

    // MARK: - Thresholds

    private let confThreshold: Double
    private let confGapThreshold: Double
    private let genaiBaseURL: String
    private static let semanticThreshold: Double = 0.55

    private static let fallbackLabel = "Default Fallback Intent"

    private let logger: Logger

    // MARK: - Init

    /// Build a classifier from a `ClassifierBundle`.
    ///
    /// - Parameters:
    ///   - bundle: which model/weights set to load. Constructed by the caller —
    ///     typically `LanguagePackRegistry.classifierBundle(for:)`.
    ///   - confThreshold: per-language decision threshold override. Nil ⇒ use
    ///     the value baked into the weights JSON.
    ///   - confGapThreshold: per-language runner-up gap override. Nil ⇒ use
    ///     the value baked into the weights JSON.
    public init(
        bundle: ClassifierBundle,
        confThreshold: Double? = nil,
        confGapThreshold: Double? = nil
    ) {
        self.bundle = bundle
        let logger = Logger(subsystem: "com.voiceintentkit", category: bundle.loggerCategory)
        self.logger = logger

        // -- Stage 2 primary: CoreML --
        // Xcode compiles .mlpackage → .mlmodelc at build time; try compiled form first.
        let intentURL =
            Bundle.module.url(forResource: bundle.modelResourceName, withExtension: "mlmodelc")
            ?? Bundle.module.url(forResource: bundle.modelResourceName, withExtension: "mlpackage")

        // Graceful degradation on a missing model — Stage 2 still runs via the
        // pure-Swift TF-IDF + LogReg fallback below.
        if let modelURL = intentURL {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            coreMLModel = try? MLModel(contentsOf: modelURL, configuration: config)
        } else {
            coreMLModel = nil
            logger.error("\(bundle.modelResourceName) not found in bundle — Stage 2 will use JSON weights fallback")
        }

        // -- Stage 2 fallback: JSON weights --
        // vocab + idf are needed on every classification (they build the tfidf_vector
        // input the CoreML model consumes), so they load eagerly here. The LogReg
        // coef matrix + intercepts (~5-25 MB) are NOT retained — they're re-loaded
        // lazily by ensureLogRegWeights() only if a CoreML prediction fails, so they
        // never sit in idle memory when CoreML is healthy.
        let jsonURL = Bundle.module.url(forResource: bundle.weightsResourceName, withExtension: "json")
        guard
            let url  = jsonURL,
            let data = try? Data(contentsOf: url),
            let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Weights JSON is required — without vocab + idf the vectoriser
            // cannot run. Build-time missing resource, not a runtime failure.
            fatalError("IntentClassifierService: \(bundle.weightsResourceName).json not found in bundle.")
        }
        weightsURL   = jsonURL
        labels       = obj["labels"] as! [String]
        vocab        = obj["vocab"]  as! [String: Int]
        idf          = obj["idf"]    as! [Double]
        genaiBaseURL = obj["genai_base_url"] as? String ?? ""
        temperature  = obj["temperature"]   as? Double ?? 1.0

        // Manifest-supplied thresholds win over the weights-JSON defaults,
        // which in turn win over the hardcoded 0.70 / 0.20 last-resort values.
        self.confThreshold    = confThreshold    ?? (obj["conf_threshold"]     as? Double) ?? 0.70
        self.confGapThreshold = confGapThreshold ?? (obj["conf_gap_threshold"] as? Double) ?? 0.20

        scorer = TFIDFLogisticScorer(
            labels: labels,
            vocab: vocab,
            idf: idf,
            temperature: temperature,
            confThreshold: self.confThreshold
        )

        // Stage 3 deliberately not loaded at init — call `loadStage3()` to
        // bring it up on demand. `semanticEmbedder` and `semanticClassifier`
        // stay nil until then; Stage 3 calls in `classifyAsync` are skipped.

        let stage2 = coreMLModel != nil ? "CoreML" : "JSON weights"
        logger.info("\(bundle.loggerCategory) ready — threshold=\(self.confThreshold), Stage2: \(stage2)")
    }

    // MARK: - Public API

    /// Pre-loads and pre-compiles the CoreML graphs (including Apple Neural
    /// Engine specialization, which happens on the first prediction) so the
    /// first real classification has no cold-start latency. Idempotent.
    public func warmUp() async {
        if let embedder = semanticEmbedder {
            _ = await embedder.embed("hello")
        }
        if let model = coreMLModel {
            _ = coreMLLogits("hello", model: model)
        }
    }

    /// Manually load Stage 3 (MiniLM embedder + semantic head) and trigger its
    /// ANE specialization. Idempotent — no-op if already loaded.
    public func loadStage3() async {
        if semanticEmbedder == nil {
            // Off the actor's executor: MiniLM init reads a 16 MB model file
            // and a 228 KB vocab.
            let task = Task.detached(priority: .userInitiated) { SemanticEmbedder() }
            semanticEmbedder = await task.value
        }
        if semanticClassifier == nil {
            semanticClassifier = SemanticClassifier()
        }
        // Trigger ANE compile / weight load — without this, the heavy memory
        // hit doesn't materialize until the first real `embed()` call.
        if let embedder = semanticEmbedder {
            _ = await embedder.embed("hello")
        }
    }

    /// Manually release Stage 3 refs. Pair with `MemoryProbe` to verify whether
    /// CoreML actually frees the ANE-resident weights when our handles drop.
    public func releaseStage3() {
        semanticEmbedder = nil
        semanticClassifier = nil
    }

    /// Full 3-stage async classification. Use this from NLUEngine.
    /// Returns `semanticRescue: true` when Stage 3 saved a low-confidence Stage 2 result.
    public func classifyAsync(_ text: String) async -> ClassificationResult {
        // Stage 1
        if let kw = keywordMatcher.match(text) {
            let bd = ClassificationBreakdown(winningStage: 1, stage2: nil, stage3: nil)
            return ClassificationResult(label: kw.label, confidence: kw.confidence,
                                        semanticRescue: false, breakdown: bd)
        }

        // Stage 2 — already off the main thread on the actor's own executor.
        let (stage2Label, stage2Conf) = stage2Classify(text)
        let s2 = ClassificationBreakdown.StageResult(stage: 2, intent: stage2Label, confidence: stage2Conf)
        let stage2Failed = stage2Label == Self.fallbackLabel || stage2Conf < confThreshold

        if !stage2Failed {
            let bd = ClassificationBreakdown(winningStage: 2, stage2: s2, stage3: nil)
            return ClassificationResult(label: stage2Label, confidence: stage2Conf,
                                        semanticRescue: false, breakdown: bd)
        }

        // Stage 3 — only when Stage 2 is uncertain AND Stage 3 was loaded.
        if let embedder = semanticEmbedder, let head = semanticClassifier,
           let embedding = await embedder.embed(text) {
            let (semLabel, semConf) = head.classify(embedding)
            let s3 = ClassificationBreakdown.StageResult(stage: 3, intent: semLabel, confidence: semConf)
            if semLabel != Self.fallbackLabel && semConf >= Self.semanticThreshold {
                logger.info("Semantic rescue: '\(text)' → \(semLabel) (\(String(format: "%.2f", semConf)))")
                let bd = ClassificationBreakdown(winningStage: 3, stage2: s2, stage3: s3)
                return ClassificationResult(label: semLabel, confidence: semConf,
                                            semanticRescue: true, breakdown: bd)
            }
            // Stage 3 ran but neither stage met threshold → GENAI fallback.
            let bd = ClassificationBreakdown(winningStage: nil, stage2: s2, stage3: s3)
            return ClassificationResult(label: stage2Label, confidence: stage2Conf,
                                        semanticRescue: false, breakdown: bd)
        }

        // Stage 3 not loaded → GENAI fallback, only Stage 2 data available.
        let bd = ClassificationBreakdown(winningStage: nil, stage2: s2, stage3: nil)
        return ClassificationResult(label: stage2Label, confidence: stage2Conf,
                                    semanticRescue: false, breakdown: bd)
    }

    /// Sync Stages 1+2 only. Used by `predict()` and legacy callers.
    public func classify(_ text: String) -> (label: String, confidence: Double) {
        if let kw = keywordMatcher.match(text) { return (kw.label, kw.confidence) }
        return stage2Classify(text)
    }

    /// Classify and apply confidence/gap thresholds, returning an `IntentResult`.
    /// Prefer `classifyAsync` from async contexts for full semantic rescue.
    public func predict(_ text: String) -> IntentResult {
        if let kw = keywordMatcher.match(text) {
            return .intent(label: kw.label, confidence: kw.confidence)
        }
        let (probs, top) = stage2Scores(text)
        guard !probs.isEmpty else { return .genai(url: genaiURL(for: text), confidence: 0.0) }
        let conf = probs[top]
        if conf >= confThreshold {
            let runnerUp = probs.indices.filter { $0 != top }.map { probs[$0] }.max() ?? 0.0
            if conf - runnerUp >= confGapThreshold {
                return .intent(label: labels[top], confidence: conf)
            }
        }
        return .genai(url: genaiURL(for: text), confidence: conf)
    }

    /// GenAI fallback URL for an unrecognised query.
    public func genaiURL(for text: String) -> URL {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return URL(string: genaiBaseURL + encoded) ?? URL(string: "https://genai.yourcompany.com")!
    }

    // MARK: - Stage 2 implementation

    /// Top intent and its (temperature-calibrated) confidence.
    private func stage2Classify(_ text: String) -> (label: String, confidence: Double) {
        let (probs, top) = stage2Scores(text)
        guard !probs.isEmpty else { return (Self.fallbackLabel, 0.0) }
        return (labels[top], probs[top])
    }

    /// Per-class Stage-2 probabilities (aligned with `labels`) plus the predicted
    /// intent index. Device contract: read raw `logits` and return
    /// `softmax(logits / temperature)`. The .mlpackage's baked `classProbability`
    /// output is never consumed — it is softmax at T = 1 and would break
    /// calibration relative to the server gate.
    private func stage2Scores(_ text: String) -> (probs: [Double], top: Int) {
        let logits = logitsForScoring(text)
        guard !logits.isEmpty else { return ([], 0) }
        let top = logits.indices.max(by: { logits[$0] < logits[$1] }) ?? 0
        return (scorer.softmaxScaled(logits), top)
    }

    /// Raw logits — CoreML's `logits` output if available, otherwise the pure-Swift
    /// TF-IDF + LogReg computation.
    private func logitsForScoring(_ text: String) -> [Double] {
        if let model = coreMLModel, let logits = coreMLLogits(text, model: model) {
            return logits
        }
        // Log every time we miss CoreML logits so silent degradation is visible
        // in Console.app (filter by subsystem com.voiceintentkit).
        logger.warning("coreMLLogits() returned nil — temperature scaling falling back to Swift TF-IDF logits. Check that \(self.bundle.modelResourceName).mlpackage exposes a 'logits' output.")
        return tfidfLogits(text)
    }

    // MARK: - CoreML Stage 2

    /// CoreML raw logits aligned with `labels`, if the model exposes a `logits`
    /// output. Returns nil otherwise so the caller falls back to Swift logits.
    private func coreMLLogits(_ text: String, model: MLModel) -> [Double]? {
        guard
            // Pass the model so the input array is built with the rank the model
            // declares for tfidf_vector ([N] vs [1, N] varies by exporter).
            let input  = scorer.coreMLInput(for: text, model: model),
            let output = try? model.prediction(from: input),
            let logits = output.featureValue(for: "logits")?.multiArrayValue,
            logits.count == labels.count
        else { return nil }
        return (0..<logits.count).map { logits[$0].doubleValue }
    }

    // MARK: - JSON weights TF-IDF (Stage 2 fallback)

    /// Loads coef + intercept on first call and caches them. Only triggered when
    /// CoreML prediction itself fails. Lock-free — this is an actor.
    @discardableResult
    private func ensureLogRegWeights() -> LogRegWeights? {
        if let w = logRegWeights { return w }
        guard
            let url  = weightsURL,
            let data = try? Data(contentsOf: url),
            let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            logger.error("LogReg fallback: failed to reload \(self.bundle.weightsResourceName).json")
            return nil
        }
        let w = LogRegWeights(
            coef:      obj["coef"]      as! [[Double]],
            intercept: obj["intercept"] as! [Double]
        )
        logger.warning("CoreML prediction failed — loaded LogReg weights into memory")
        logRegWeights = w
        return w
    }

    private func tfidfLogits(_ text: String) -> [Double] {
        guard let w = ensureLogRegWeights() else { return [Double](repeating: 0, count: labels.count) }
        let vec = scorer.tfidfVector(for: text)
        return w.coef.indices.map { c in
            zip(w.coef[c], vec).reduce(w.intercept[c]) { $0 + $1.0 * $1.1 }
        }
    }
}
