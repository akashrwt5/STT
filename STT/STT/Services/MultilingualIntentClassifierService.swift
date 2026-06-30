// MultilingualIntentClassifierService.swift
// STT
//
// Multilingual peer of IntentClassifierService. Same 3-stage architecture
// (Stage 1 keyword → Stage 2 TF-IDF + CoreML LogReg → Stage 3 MiniLM rescue),
// same shared TFIDFLogisticScorer math, same shared Stage 3 (SemanticEmbedder +
// SemanticClassifier). The only differences are the Stage-2 resource names and a
// graceful (non-fatal) degradation when the newer multilingual .mlpackage is
// absent from a stale bundle.
//
// Placement: this lives at Services/ — a peer of IntentClassifierService — because
// a classifier is a service, not an NLU orchestration type. Services/NLU/ holds
// orchestration (NLUEngine, EntityExtractor, NLUSchema); the two classifiers are
// peers at the same architectural layer.
//
// TODO(multilingual-schema): slot prompts and entity extraction currently use the
// English nlu_schema.json and nlu_entities.json (loaded by NLUEngine /
// EntityExtractor), so prompts surface in English regardless of input language.
// True per-language slot-filling requires per-language schema files injected via
// the factory. Tracked as a follow-up; see docs/MULTILINGUAL_NLU_IMPLEMENTATION.md §4.

import CoreML
import Foundation
import os.log

// MARK: - Service

// `actor` for the same reasons as IntentClassifierService: serial off-main
// execution and lock-free serialisation of mutable state (coreMLModel,
// logRegWeights, semanticEmbedder) without @unchecked Sendable.
public actor MultilingualIntentClassifierService: IntentClassifying {

    // MARK: - Resource location
    //
    // The Multilingual/ folder lives inside the STT file-system-synchronized root
    // group, whose subfolders are mirrored as Xcode groups — so resources flatten
    // to the bundle root and `subdirectory` is nil. If the folder is ever converted
    // to a blue folder reference, set this to "Multilingual" (the files would then
    // land under Multilingual/ in the bundle). Confirmed against project.pbxproj.
    private static let resourceSubdir: String? = nil

    // MARK: - Lifecycle

    deinit {
        print("[Deinit] MultilingualIntentClassifierService")
    }

    // MARK: - Stage 1

    private let keywordMatcher = KeywordMatcher()

    // MARK: - Stage 2 — CoreML (primary)

    private let coreMLModel: MLModel?

    // MARK: - Stage 2 — JSON weights fallback

    private let labels: [String]
    private let vocab: [String: Int]
    private let idf: [Double]

    /// LogReg coefficient matrix and intercepts — only materialised when CoreML
    /// prediction itself fails. Value-type so it can be nilled to reclaim memory.
    private struct LogRegWeights {
        let coef: [[Double]]
        let intercept: [Double]
    }

    private var logRegWeights: LogRegWeights?
    private let weightsURL: URL?

    /// Temperature for the `softmax(logits / T)` confidence contract. Shipped in
    /// multilingual_intent_classifier_weights.json; a missing key ⇒ T = 1.0.
    private let temperature: Double

    /// Shared, stateless vectorisation + confidence math. Identical type to the
    /// one IntentClassifierService holds — the TF-IDF → softmax(logits/T) math is
    /// written once and reused, never duplicated.
    private let scorer: TFIDFLogisticScorer

    // MARK: - Stage 3 (shared, unchanged)
    //
    // SemanticEmbedder loads MiniLMEmbedder.mlpackage and semantic_head.json from
    // the root Resources/ dir — these are shared English Stage-3 resources already
    // correctly placed, so they need no subdirectory. A future iteration may inject
    // a multilingual embedder/head here; the on-demand load/release lifecycle below
    // is deliberately variant-agnostic so that swap is a constructor change only.

    private var semanticEmbedder: SemanticEmbedder?
    private var semanticClassifier: SemanticClassifier?

    // MARK: - Thresholds

    private let confThreshold: Double
    private let confGapThreshold: Double
    private let genaiBaseURL: String
    private static let semanticThreshold: Double = 0.55

    private static let fallbackLabel = "Default Fallback Intent"

    private let logger = Logger(subsystem: "com.stt.module", category: "MultilingualIntentClassifier")

    // MARK: - Init

    /// Create a classifier calibrated for a specific language.
    ///
    /// When `language` is provided the service reads per-language confidence
    /// thresholds from `Multilingual/calibration.json` (bundled alongside the
    /// weights file). This implements Phase-3 threshold tuning: each language
    /// has a different optimal conf_threshold discovered by sweeping the
    /// held-out split (see `scripts/calibrate_languages.py`). Falls back to
    /// the model-default threshold if the calibration file is absent or the
    /// language key is missing. Temperature is read from the model weights JSON
    /// and is unaffected by calibration.json.
    public init(language: String = "multilingual") {
        // -- Stage 2 primary: CoreML --
        let intentURL =
            Bundle.main.url(forResource: "IntentClassifier_multilingual",
                            withExtension: "mlmodelc", subdirectory: Self.resourceSubdir)
            ?? Bundle.main.url(forResource: "IntentClassifier_multilingual",
                               withExtension: "mlpackage", subdirectory: Self.resourceSubdir)

        // Graceful degradation — do NOT fatalError on a missing model. The
        // multilingual .mlpackage is newer than the JSON weights; if a stale bundle
        // lacks it, degrade to the pure-Swift TF-IDF + LogReg path rather than
        // crashing the whole app over an optional resource.
        if let modelURL = intentURL {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            coreMLModel = try? MLModel(contentsOf: modelURL, configuration: config)
        } else {
            coreMLModel = nil
            Logger(subsystem: "com.stt.module", category: "MultilingualIntentClassifier")
                .error("IntentClassifier_multilingual not found in bundle — Stage 2 will use JSON weights fallback")
        }

        // -- Stage 2 fallback: JSON weights --
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
            // Weights JSON is required — without vocab + idf the vectoriser cannot
            // run. This is a build-time error (missing vendored resource), not a
            // runtime one, so a hard failure here is correct.
            fatalError("MultilingualIntentClassifierService: multilingual_intent_classifier_weights.json not found in bundle.")
        }
        weightsURL = jsonURL
        labels     = obj["labels"] as! [String]
        vocab      = obj["vocab"]  as! [String: Int]
        idf        = obj["idf"]    as! [Double]
        temperature = obj["temperature"] as? Double ?? 1.0
        genaiBaseURL = obj["genai_base_url"] as? String ?? ""

        // Per-language calibration overrides (Phase 3). calibration.json lives
        // next to the weights file in Multilingual/. Falls back to the model
        // defaults when the file or the language key is absent.
        let calURL = Bundle.main.url(forResource: "calibration", withExtension: "json",
                                     subdirectory: Self.resourceSubdir)
        let calObj: [String: Any]? = calURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        let langEntry = calObj?[language] as? [String: Any]
        confThreshold    = langEntry?["conf_threshold"]     as? Double
                        ?? obj["conf_threshold"]            as? Double
                        ?? 0.70
        confGapThreshold = langEntry?["conf_gap_threshold"] as? Double
                        ?? obj["conf_gap_threshold"]        as? Double
                        ?? 0.20

        scorer = TFIDFLogisticScorer(
            labels: labels,
            vocab: vocab,
            idf: idf,
            temperature: temperature,
            confThreshold: confThreshold
        )

        let stage2 = coreMLModel != nil ? "CoreML" : "JSON weights"
        Logger(subsystem: "com.stt.module", category: "MultilingualIntentClassifier")
            .info("MultilingualIntentClassifier ready — lang=\(language), threshold=\(confThreshold), Stage2: \(stage2)")
    }

    // MARK: - Public API

    /// Pre-loads and pre-compiles the CoreML graphs (incl. ANE specialisation) so
    /// the first real classification has no cold-start latency. Idempotent.
    public func warmUp() async {
        if let embedder = semanticEmbedder {
            _ = await embedder.embed("hello")
        }
        if let model = coreMLModel {
            _ = coreMLLogits("hello", model: model)
        }
    }

    /// Manually load Stage 3 (MiniLM embedder + semantic head) and trigger ANE
    /// specialisation. Idempotent — no-op if already loaded.
    public func loadStage3() async {
        if semanticEmbedder == nil {
            let task = Task.detached(priority: .userInitiated) { SemanticEmbedder() }
            semanticEmbedder = await task.value
        }
        if semanticClassifier == nil {
            semanticClassifier = SemanticClassifier()
        }
        if let embedder = semanticEmbedder {
            _ = await embedder.embed("hello")
        }
    }

    /// Manually release Stage 3 refs. Stage 3 is skipped on future classifications.
    public func releaseStage3() {
        semanticEmbedder = nil
        semanticClassifier = nil
    }

    /// Full 3-stage async classification. Returns `semanticRescue: true` when
    /// Stage 3 rescued a low-confidence Stage 2 result.
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
            let bd = ClassificationBreakdown(winningStage: nil, stage2: s2, stage3: s3)
            return ClassificationResult(label: stage2Label, confidence: stage2Conf,
                                        semanticRescue: false, breakdown: bd)
        }

        // Stage 3 not loaded → GENAI fallback, only Stage 2 data available.
        let bd = ClassificationBreakdown(winningStage: nil, stage2: s2, stage3: nil)
        return ClassificationResult(label: stage2Label, confidence: stage2Conf,
                                    semanticRescue: false, breakdown: bd)
    }

    /// Sync Stages 1+2 only.
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
    /// `softmax(logits / temperature)`. The baked `classProbability` output is
    /// never consumed — it is softmax at T = 1 and breaks calibration.
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
        logger.warning("coreMLLogits() returned nil — temperature scaling falling back to Swift TF-IDF logits. Check that IntentClassifier_multilingual.mlpackage exposes a 'logits' output.")
        return tfidfLogits(text)
    }

    // MARK: - CoreML Stage 2

    /// CoreML raw logits aligned with `labels`, if the model exposes a "logits"
    /// output. Returns nil otherwise so the caller falls back to Swift logits.
    private func coreMLLogits(_ text: String, model: MLModel) -> [Double]? {
        guard
            let input  = scorer.coreMLInput(for: text),
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
            logger.error("LogReg fallback: failed to reload multilingual_intent_classifier_weights.json")
            return nil
        }
        let w = LogRegWeights(
            coef:      obj["coef"]      as! [[Double]],
            intercept: obj["intercept"] as! [Double]
        )
        logger.warning("CoreML prediction failed — loaded multilingual LogReg weights into memory")
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
