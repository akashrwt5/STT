// IntentClassifierService.swift
// STT
//
// Pure-Swift TF-IDF + Logistic Regression inference.
// Mirrors the logic in IntentClassifier/scripts/predict.py — no external dependencies.

import Foundation

/// Runs on-device intent classification using weights pre-exported from the Python training pipeline.
public final class IntentClassifierService: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = IntentClassifierService()

    // MARK: - Model weights (loaded once)

    private let labels: [String]
    private let vocab: [String: Int]
    private let idf: [Double]
    private let coef: [[Double]]       // [nClasses][nFeatures]
    private let intercept: [Double]    // [nClasses]
    private let confThreshold: Double
    private let confGapThreshold: Double
    private let genaiBaseURL: String

    // MARK: - Init

    private init() {
        guard
            let url = Bundle.main.url(forResource: "intent_classifier_weights", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            fatalError("IntentClassifierService: intent_classifier_weights.json not found in app bundle.")
        }

        labels           = obj["labels"]           as! [String]
        vocab            = obj["vocab"]             as! [String: Int]
        idf              = obj["idf"]               as! [Double]
        coef             = obj["coef"]              as! [[Double]]
        intercept        = obj["intercept"]         as! [Double]
        confThreshold    = obj["conf_threshold"]    as? Double ?? 0.70
        confGapThreshold = obj["conf_gap_threshold"] as? Double ?? 0.20
        genaiBaseURL     = obj["genai_base_url"]    as? String ?? ""
    }

    // MARK: - Public API

    /// Raw classification: the single most likely label and its softmax probability.
    /// Unlike `predict`, this applies no confidence/gap thresholding and may return
    /// `OUT_OF_SCOPE`. Used by the NLU engine, which applies its own policy.
    /// Safe to call from any thread/Task.
    public func classify(_ text: String) -> (label: String, confidence: Double) {
        let probs = softmax(logitScores(tfidfVector(for: text)))
        let top = probs.indices.max(by: { probs[$0] < probs[$1] })!
        return (labels[top], probs[top])
    }

    /// The GenAI fallback URL for an unrecognised query.
    public func genaiURL(for text: String) -> URL {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return URL(string: genaiBaseURL + encoded) ?? URL(string: "https://genai.yourcompany.com")!
    }

    /// Classify `text` and return an `IntentResult`.
    /// Safe to call from any thread/Task.
    public func predict(_ text: String) -> IntentResult {
        let vec = tfidfVector(for: text)
        let logits = logitScores(vec)
        let probs = softmax(logits)

        let top1 = probs.indices.max(by: { probs[$0] < probs[$1] })!
        let conf1 = probs[top1]

        var sortedProbs = probs.enumerated().map { ($0.offset, $0.element) }
        sortedProbs.sort { $0.1 > $1.1 }
        let conf2 = sortedProbs.count > 1 ? sortedProbs[1].1 : 0.0
        let gap = conf1 - conf2

        if conf1 >= confThreshold && gap >= confGapThreshold {
            return .intent(label: labels[top1], confidence: conf1)
        }

        return .genai(url: genaiURL(for: text), confidence: conf1)
    }

    // MARK: - TF-IDF

    private func tfidfVector(for text: String) -> [Double] {
        let tokens = tokenize(text)
        var termCounts: [Int: Int] = [:]
        for token in tokens {
            if let idx = vocab[token] {
                termCounts[idx, default: 0] += 1
            }
        }

        var vec = [Double](repeating: 0.0, count: idf.count)
        for (idx, count) in termCounts {
            let tf = 1.0 + log(Double(count))   // sublinear TF
            vec[idx] = tf * idf[idx]
        }
        return l2Normalize(vec)
    }

    /// Produces unigrams and bigrams from lowercased text, matching sklearn's tokenizer.
    private func tokenize(_ text: String) -> [String] {
        let lower = text.lowercased()
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
                         .filter { !$0.isEmpty }
        var tokens = words
        for i in 0..<(words.count - 1) {
            tokens.append(words[i] + " " + words[i + 1])
        }
        return tokens
    }

    // MARK: - Linear classifier

    private func logitScores(_ vec: [Double]) -> [Double] {
        return coef.indices.map { c in
            zip(coef[c], vec).reduce(intercept[c]) { $0 + $1.0 * $1.1 }
        }
    }

    // MARK: - Math helpers

    private func softmax(_ logits: [Double]) -> [Double] {
        let maxVal = logits.max() ?? 0
        let exps = logits.map { exp($0 - maxVal) }
        let sum = exps.reduce(0, +)
        return sum == 0 ? logits.map { _ in 1.0 / Double(logits.count) } : exps.map { $0 / sum }
    }

    private func l2Normalize(_ vec: [Double]) -> [Double] {
        let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vec }
        return vec.map { $0 / norm }
    }
}
