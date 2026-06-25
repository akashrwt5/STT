// TFIDFLogisticScorer.swift
// STT
//
// The shared Stage-2 vectorisation + confidence math. Written once here and
// consumed by both IntentClassifierService (English) and
// MultilingualIntentClassifierService — neither duplicates the 80 lines of
// TF-IDF / softmax math.

import CoreML
import Foundation

// MARK: - TFIDFLogisticScorer

/// Stateless TF-IDF → L2-normalise → CoreML logits → `softmax(logits / T)` scorer.
///
/// A value type (`struct`) because it is stateless after construction: every
/// method is a pure function over immutable inputs (`vocab`, `idf`, `temperature`,
/// `labels`). Value types are the correct tool for stateless computation — no
/// identity, no mutation, no synchronisation. Making it an actor would add an
/// executor hop for work that already runs inside a classifier actor's methods.
///
/// Device confidence contract (invariant):
///   `confidence = softmax(logits / temperature)[argmax]`
///   `temperature` is read from the weights JSON; a missing key ⇒ `T = 1.0`.
///   The `.mlpackage`'s baked `classProbability` output is NEVER consumed — it is
///   softmax at `T = 1` and would break the server-side calibration contract.
public struct TFIDFLogisticScorer {

    // MARK: - Immutable model parameters

    public let labels: [String]
    public let vocab: [String: Int]
    public let idf: [Double]
    /// Shipped per-model calibration scalar. `T = 1.0` degrades to plain softmax.
    public let temperature: Double
    /// Confidence gate. Predictions below this score fall through to Stage 3.
    public let confThreshold: Double

    // MARK: - Init

    public init(
        labels: [String],
        vocab: [String: Int],
        idf: [Double],
        temperature: Double,
        confThreshold: Double
    ) {
        self.labels        = labels
        self.vocab         = vocab
        self.idf           = idf
        // Enforce a positive temperature once, at construction. A non-positive
        // shipped value (or a missing key resolved to 0) degrades to plain softmax.
        self.temperature   = temperature > 0 ? temperature : 1.0
        self.confThreshold = confThreshold
    }

    // MARK: - CoreML input

    /// Builds a FLOAT32 `MLMultiArray` feature provider from the TF-IDF vector.
    ///
    /// The mlprogram exporter declares `tfidf_vector` as FLOAT32; CoreML rejects
    /// a dtype mismatch by refusing the prediction (which would silently fall back
    /// to the JSON-weights path), so the array is always built as `.float32`.
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

    /// `softmax(logits / T)` — the device confidence contract. `T` is enforced
    /// positive at init; a non-positive value is treated as 1.0 defensively.
    /// Rank-preserving, so the predicted intent (raw-logit argmax) is unchanged.
    public func softmaxScaled(_ logits: [Double]) -> [Double] {
        softmax(logits.map { $0 / temperature })
    }
}
