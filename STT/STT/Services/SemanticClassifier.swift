// SemanticClassifier.swift
// STT
//
// Stage 3 linear head: logistic regression over MiniLM-L6-v2 embeddings.
// Mirrors SemanticFallback.classify() in IntentClassifier/scripts/nlu/semantic.py.
//
// Artifact: semantic_head.json (copy from IntentClassifier/models/semantic_head.json)
// Structure: { "labels": [...], "weights": [[...]], "bias": [...] }
//   weights shape: [nClasses × 384]  bias shape: [nClasses]
//
// If the file is absent from the bundle, init() returns nil and the caller
// skips Stage 3 entirely — graceful degradation to GenAI fallback.

import Foundation

final class SemanticClassifier {

    private let labels: [String]
    private let weights: [[Float]]   // [nClasses × 384]
    private let bias: [Float]        // [nClasses]

    /// Minimum softmax probability to accept the head's answer.
    /// Matches Python DEFAULT_THRESHOLD = 0.55 (tuned on semantic_holdout_100.csv).
    let threshold: Double = 0.55

    // MARK: - Init

    init?() {
        guard
            let url  = Bundle.main.url(forResource: "semantic_head", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let lbls = obj["labels"]  as? [String],
            let wRaw = obj["weights"] as? [[Double]],
            let bRaw = obj["bias"]    as? [Double]
        else { return nil }

        labels  = lbls
        weights = wRaw.map { $0.map(Float.init) }
        bias    = bRaw.map(Float.init)
    }

    // MARK: - Public API

    /// Classifies a 384-dim L2-normalised embedding.
    /// Returns (label, confidence). The caller should check `confidence >= threshold`.
    func classify(_ embedding: [Float]) -> (label: String, confidence: Double) {
        var logits = [Float](repeating: 0, count: labels.count)
        for (c, row) in weights.enumerated() {
            var sum = bias[c]
            for i in row.indices { sum += row[i] * embedding[i] }
            logits[c] = sum
        }

        // Numerically-stable softmax (subtract max before exp)
        let maxVal = logits.max() ?? 0
        var exps   = logits.map { exp($0 - maxVal) }
        let total  = exps.reduce(0, +)
        if total > 0 { exps = exps.map { $0 / total } }

        let top = exps.indices.max(by: { exps[$0] < exps[$1] })!
        return (labels[top], Double(exps[top]))
    }
}
