// SemanticClassifier.swift
// STT
//
// Stage 3 linear head: logistic regression over MiniLM-L6-v2 embeddings.
// Mirrors SemanticFallback.classify() in IntentClassifier/scripts/nlu/semantic.py.
//
// Primary:  SemanticHead.mlpackage  (CoreML, input: embedding[384], output: classProbability)
// Fallback: semantic_head.json      (pure-Swift, used if .mlpackage absent from bundle)
//
// If neither artifact is present, init() returns nil and the caller
// skips Stage 3 entirely — graceful degradation to Stage 2 only.

import CoreML
import Foundation

final class SemanticClassifier {

    private enum Backend {
        case coreML(MLModel, [String])          // model + label order
        case swift([String], [[Float]], [Float]) // labels, weights, bias
    }

    private let backend: Backend

    deinit {
        print("[Deinit] SemanticClassifier (MLModel released)")
    }

    /// Minimum softmax probability to accept the head's answer.
    /// Matches Python DEFAULT_THRESHOLD = 0.55 (tuned on semantic_holdout_100.csv).
    let threshold: Double = 0.55

    // MARK: - Init

    init?() {
        // Primary: CoreML SemanticHead.mlpackage
        if let modelURL = Bundle.main.url(forResource: "SemanticHead", withExtension: "mlpackage")
                       ?? Bundle.main.url(forResource: "SemanticHead", withExtension: "mlmodelc"),
           let model = try? MLModel(contentsOf: modelURL) {
            // Read label order from the model spec so argmax aligns with classProbability dict.
            let labels: [String]
            if let classLabels = model.modelDescription.classLabels as? [String] {
                labels = classLabels
            } else {
                // Fall back to JSON for label order if spec doesn't expose them.
                guard let order = Self.labelsFromJSON() else { return nil }
                labels = order
            }
            backend = .coreML(model, labels)
            return
        }

        // Fallback: pure-Swift JSON weights
        guard
            let url  = Bundle.main.url(forResource: "semantic_head", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let lbls = obj["labels"]  as? [String],
            let wRaw = obj["weights"] as? [[Double]],
            let bRaw = obj["bias"]    as? [Double]
        else { return nil }

        backend = .swift(lbls, wRaw.map { $0.map(Float.init) }, bRaw.map(Float.init))
    }

    // MARK: - Public API

    /// Classifies a 384-dim L2-normalised embedding.
    /// Returns (label, confidence). The caller should check `confidence >= threshold`.
    func classify(_ embedding: [Float]) -> (label: String, confidence: Double) {
        switch backend {
        case .coreML(let model, let labels):
            return classifyWithCoreML(embedding, model: model, labels: labels)
        case .swift(let labels, let weights, let bias):
            return classifyWithSwift(embedding, labels: labels, weights: weights, bias: bias)
        }
    }

    // MARK: - CoreML path

    private func classifyWithCoreML(_ embedding: [Float],
                                    model: MLModel,
                                    labels: [String]) -> (label: String, confidence: Double) {
        guard
            let arr  = try? MLMultiArray(shape: [embedding.count as NSNumber], dataType: .float32),
            let _    = embedding.withUnsafeBytes({ ptr in
                arr.dataPointer.copyMemory(from: ptr.baseAddress!, byteCount: embedding.count * 4)
                return Optional<Void>.some(())
            }),
            let input  = try? MLDictionaryFeatureProvider(dictionary: ["embedding": MLFeatureValue(multiArray: arr)]),
            let output = try? model.prediction(from: input),
            let probs  = output.featureValue(for: "classProbability")?.dictionaryValue as? [String: NSNumber]
        else {
            // CoreML prediction failed; fall back to Swift path using empty weights (unknown)
            return ("Default Fallback Intent", 0.0)
        }

        // Re-align dict → labels order for consistent argmax
        let probVec = labels.map { probs[$0]?.doubleValue ?? 0.0 }
        let top = probVec.indices.max(by: { probVec[$0] < probVec[$1] }) ?? 0
        return (labels[top], probVec[top])
    }

    // MARK: - Pure-Swift path

    private func classifyWithSwift(_ embedding: [Float],
                                   labels: [String],
                                   weights: [[Float]],
                                   bias: [Float]) -> (label: String, confidence: Double) {
        var logits = [Float](repeating: 0, count: labels.count)
        for (c, row) in weights.enumerated() {
            var sum = bias[c]
            for i in row.indices { sum += row[i] * embedding[i] }
            logits[c] = sum
        }
        let maxVal = logits.max() ?? 0
        var exps   = logits.map { exp($0 - maxVal) }
        let total  = exps.reduce(0, +)
        if total > 0 { exps = exps.map { $0 / total } }
        let top = exps.indices.max(by: { exps[$0] < exps[$1] })!
        return (labels[top], Double(exps[top]))
    }

    // MARK: - Helpers

    private static func labelsFromJSON() -> [String]? {
        guard
            let url  = Bundle.main.url(forResource: "semantic_head", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let lbls = obj["labels"] as? [String]
        else { return nil }
        return lbls
    }
}
