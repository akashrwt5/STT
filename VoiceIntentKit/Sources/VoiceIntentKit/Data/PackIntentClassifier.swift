// PackIntentClassifier.swift
// VoiceIntentKit
//
// Stage 2, driven entirely by a `ResolvedPack`. Replaces
// `IntentClassifierService`, which resolved everything through `Bundle.module`
// and called `fatalError` when a resource was absent.
//
// Three things changed, all of them deliberate:
//
//  1. NO `Bundle.module`. Every artifact URL comes from the pack.
//  2. NO `fatalError`. A missing artifact is a runtime condition once packs are
//     downloaded, so `init` throws and the caller decides.
//  3. `.cpuOnly`, not `.all`. ADR-017 measured `.all` on this exact head:
//     93.7 ms to load versus 15.6 ms, +1.69 MB of app footprint, and — the
//     reason it is not merely a performance choice — ANE and CPU return
//     DIFFERENT logits from the same model, so under `.all` the backend is
//     CoreML's choice and the same shipped model is not reproducible run to
//     run. Under a 0.70 gate with canary cohorts that is undebuggable.
//
// Stage 2 has two paths and both are real: the CoreML head, and a pure-Swift
// TF-IDF + logistic fallback over the same weights. The fallback is not a
// pretend safety net — a pack compiled without the iOS artifacts has no CoreML
// head at all, and the classifier still works.

import CoreML
import Foundation
import os.log

actor PackIntentClassifier {

    // MARK: - Result

    struct Prediction: Sendable, Equatable {
        let intent: String
        /// `softmax(logits / temperature)[argmax]` — the device confidence
        /// contract. Never CoreML's baked `classProbability`, which is softmax
        /// at T=1 and would discard the pack's calibration.
        let confidence: Double
        /// Gap to the runner-up. A confident-looking top score with a close
        /// second is a different situation from a clear win.
        let margin: Double
        /// Whether this cleared both the confidence and the gap thresholds.
        let passesGate: Bool
        /// True when the utterance produced no features at all, so the scores
        /// are the model's priors rather than a reading of the input.
        let isVacuous: Bool
        let backend: Backend

        enum Backend: String, Sendable { case coreML, pureSwift }
    }

    // MARK: - State

    private let artifacts: ResolvedPack.ClassifierArtifacts
    private let vectorizer: PackTFIDFVectorizer
    private let temperature: Double
    private let confidenceThreshold: Double
    private let gapThreshold: Double
    private let log: Logger

    private var model: MLModel?

    /// Coefficients are the largest single allocation here — 57 × 4718 doubles
    /// is ~2 MB for the full head. They are only needed when CoreML is absent
    /// or a prediction fails, so they load on first use and not before.
    private var coefficients: (weights: [[Double]], intercepts: [Double])?

    // MARK: - Init

    /// - Throws: `VoiceIntentError` when the weights cannot be read or the
    ///   vocabulary does not match the label space. Never traps.
    init(artifacts: ResolvedPack.ClassifierArtifacts) throws {
        self.artifacts = artifacts
        self.temperature = artifacts.temperature > 0 ? artifacts.temperature : 1.0
        self.confidenceThreshold = artifacts.confidenceThreshold
        self.gapThreshold = artifacts.confidenceGapThreshold
        self.log = Logger(subsystem: "com.voiceintentkit",
                          category: "IntentClassifier.\(artifacts.variant.rawValue)")

        // vocab + idf are needed for EVERY classification — they build the
        // vector the CoreML head consumes — so they cannot be deferred.
        let relative = artifacts.weightsURL.lastPathComponent
        guard let data = try? Data(contentsOf: artifacts.weightsURL) else {
            throw VoiceIntentError.unreadableFile(path: relative, reason: "not readable")
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let vocabulary = root["vocab"] as? [String: Int],
            let idf = root["idf"] as? [Double]
        else {
            throw VoiceIntentError.malformedJSON(path: relative, reason: "vocab/idf absent")
        }
        self.vectorizer = PackTFIDFVectorizer(vocabulary: vocabulary, idf: idf)

        log.info("""
            \(artifacts.variant.rawValue, privacy: .public) head — \
            vocab \(vocabulary.count), \(artifacts.labels.count) labels, T=\(self.temperature), \
            gate \(self.confidenceThreshold)/\(self.gapThreshold), \
            CoreML \(artifacts.model == nil ? "absent" : "present", privacy: .public)
            """)
    }

    // MARK: - Lifecycle

    /// Load the CoreML head and run one throwaway prediction.
    ///
    /// Idempotent. Worth calling before the first utterance: the load itself is
    /// ~15 ms on `.cpuOnly` and the first prediction carries a small extra cost,
    /// which is latency the user would otherwise wait through.
    func warmUp() async {
        guard model == nil, let artifact = artifacts.model else { return }
        do {
            model = try Self.loadModel(at: artifact, log: log)
            _ = predictWithCoreML("warm up")
        } catch {
            // Not fatal: the pure-Swift path covers this, with a real accuracy
            // contract rather than a stub.
            log.error("""
                CoreML head unavailable (\(String(describing: error), privacy: .public)) — \
                falling back to the pure-Swift path
                """)
            model = nil
        }
    }

    /// Release the CoreML head. The next `warmUp()` reloads it.
    func unload() {
        model = nil
        coefficients = nil
    }

    // MARK: - Classification

    func classify(_ text: String) -> Prediction {
        let vector = vectorizer.vectorize(text)

        // No feature matched. Every logit is its intercept, so argmax is a fixed
        // label and the softmax over it is meaningless — but it can still clear
        // 0.70. Report it rather than let a caller act on a prior.
        if vector.isEmpty {
            return Prediction(intent: artifacts.labels.first ?? "",
                              confidence: 0, margin: 0, passesGate: false,
                              isVacuous: true, backend: .pureSwift)
        }

        if model != nil, let prediction = predictWithCoreML(text) {
            return prediction
        }
        return predictWithWeights(vector)
    }

    // MARK: - CoreML path

    private func predictWithCoreML(_ text: String) -> Prediction? {
        guard let model else { return nil }
        let dense = vectorizer.denseVector(text)
        guard
            let input = Self.featureProvider(dense, model: model),
            let output = try? model.prediction(from: input),
            let logits = Self.logits(from: output, expected: artifacts.labels.count)
        else {
            log.error("CoreML prediction failed — using the pure-Swift path for this turn")
            return nil
        }
        return score(logits, backend: .coreML)
    }

    private static func featureProvider(_ dense: [Float], model: MLModel) -> MLFeatureProvider? {
        // The declared rank differs between exporters — the NeuralNetworkBuilder
        // head takes rank 1 [N], an ML Program export rank 2 [1, N]. The memory
        // layout is identical, so read the shape from the model rather than
        // assuming: a mismatch makes CoreML refuse the prediction outright.
        let shape: [NSNumber]
        if let constraint = model.modelDescription
            .inputDescriptionsByName["tfidf_vector"]?.multiArrayConstraint,
           !constraint.shape.isEmpty {
            var declared = constraint.shape
            for i in declared.indices where declared[i].intValue <= 0 {
                declared[i] = (i == declared.count - 1) ? NSNumber(value: dense.count) : 1
            }
            shape = declared
        } else {
            shape = [NSNumber(value: dense.count)]
        }
        guard let array = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }
        let buffer = array.dataPointer.assumingMemoryBound(to: Float.self)
        for i in dense.indices { buffer[i] = dense[i] }
        return try? MLDictionaryFeatureProvider(
            dictionary: ["tfidf_vector": MLFeatureValue(multiArray: array)])
    }

    private static func logits(from output: MLFeatureProvider, expected: Int) -> [Double]? {
        // Read raw logits only. CoreML's `classProbability` is softmax at T=1;
        // consuming it would throw away the pack's calibration and silently
        // change every gate decision.
        for name in output.featureNames {
            guard let array = output.featureValue(for: name)?.multiArrayValue,
                  array.count == expected else { continue }
            return (0..<array.count).map { array[$0].doubleValue }
        }
        return nil
    }

    private static func loadModel(at artifact: ResolvedPack.ClassifierArtifacts.ModelArtifact,
                                  log: Logger) throws -> MLModel {
        let configuration = MLModelConfiguration()
        // ADR-017. Not a tuning preference: `.all` costs 93.7 ms vs 15.6 ms to
        // load, +1.69 MB footprint, and returns different logits than CPU for
        // the same model — non-reproducibility under a confidence gate.
        configuration.computeUnits = .cpuOnly

        if artifact.isCompiled {
            // `MLModel(contentsOf:)` REQUIRES a compiled model, and
            // `compileModel(at:)` REJECTS one — so the two branches are not
            // interchangeable and the flag decides which API is legal.
            return try MLModel(contentsOf: artifact.url, configuration: configuration)
        }
        // Only reached for a pack that ships `.mlpackage` without a compiled
        // sibling. Packs from 1.0.28 carry `.mlmodelc`, so this is a
        // compatibility path, not the norm — which is why there is no compiled
        // artifact cache here to maintain or invalidate.
        log.notice("Pack ships an uncompiled .mlpackage — compiling on device")
        let compiled = try MLModel.compileModel(at: artifact.url)
        return try MLModel(contentsOf: compiled, configuration: configuration)
    }

    // MARK: - Pure-Swift path

    private func predictWithWeights(_ vector: [Int: Double]) -> Prediction {
        guard let coefficients = ensureCoefficients() else {
            return Prediction(intent: artifacts.labels.first ?? "",
                              confidence: 0, margin: 0, passesGate: false,
                              isVacuous: true, backend: .pureSwift)
        }
        var logits = coefficients.intercepts
        for (row, weights) in coefficients.weights.enumerated() {
            var sum = logits[row]
            for (column, value) in vector { sum += weights[column] * value }
            logits[row] = sum
        }
        return score(logits, backend: .pureSwift)
    }

    private func ensureCoefficients() -> (weights: [[Double]], intercepts: [Double])? {
        if let coefficients { return coefficients }
        guard
            let data = try? Data(contentsOf: artifacts.weightsURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let coef = root["coef"] as? [[Double]],
            let intercept = root["intercept"] as? [Double]
        else {
            log.error("Weights JSON has no usable coef/intercept — cannot classify")
            return nil
        }
        coefficients = (coef, intercept)
        return coefficients
    }

    // MARK: - Scoring

    private func score(_ logits: [Double], backend: Prediction.Backend) -> Prediction {
        guard !logits.isEmpty, logits.count == artifacts.labels.count else {
            return Prediction(intent: artifacts.labels.first ?? "",
                              confidence: 0, margin: 0, passesGate: false,
                              isVacuous: true, backend: backend)
        }
        // Temperature scaling is rank-preserving, so argmax is taken on the raw
        // logits and only the confidence is scaled.
        var best = 0
        for i in logits.indices where logits[i] > logits[best] { best = i }

        let scaled = logits.map { $0 / temperature }
        let maximum = scaled.max() ?? 0
        let exponentials = scaled.map { exp($0 - maximum) }
        let total = exponentials.reduce(0, +)
        let probabilities = total > 0
            ? exponentials.map { $0 / total }
            : [Double](repeating: 1.0 / Double(logits.count), count: logits.count)

        let confidence = probabilities[best]
        var runnerUp = 0.0
        for i in probabilities.indices where i != best {
            if probabilities[i] > runnerUp { runnerUp = probabilities[i] }
        }
        let margin = confidence - runnerUp

        return Prediction(intent: artifacts.labels[best],
                          confidence: confidence,
                          margin: margin,
                          passesGate: confidence >= confidenceThreshold && margin >= gapThreshold,
                          isVacuous: false,
                          backend: backend)
    }
}
