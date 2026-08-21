// PackTFIDFVectorizer.swift
// VoiceIntentKit
//
// Turns text into the feature vector the CoreML head expects.
//
// THIS MUST MATCH THE TRAINER EXACTLY. The model was fitted by scikit-learn's
// TfidfVectorizer; iOS re-implements that vectorisation in Swift and feeds the
// result to a head trained on the Python side. Any divergence is silent — no
// crash, no log, just features that never match and confidence that quietly
// drops below the gate.
//
// Measured on `holdout_honest.csv` (n=1470) against the pruned predecessor,
// `TFIDFLogisticScorer`, which split on non-alphanumerics and kept every
// non-empty token:
//
//     trainer tokenisation   acc 0.9027   gate-pass 0.8823
//     predecessor            acc 0.9020   gate-pass 0.8735
//     11 label disagreements (0.75%)
//
// Accuracy barely moved; GATE-PASS lost 0.88pp, which is the number that
// matters — 13 more utterances per 1470 fall under the 0.70 threshold and get a
// reprompt instead of an action. The cause is subtle: sklearn's default
// `token_pattern` requires TWO word characters, so 1-character tokens are
// dropped BEFORE bigrams are formed. "set a reminder" gives the trainer
// `set reminder`; keeping the "a" yields `set a` + `a reminder` and the trained
// feature is never produced.
//
// The vectoriser's parameters are NOT in the pack — `ngram_range`, `min_df`,
// `sublinear_tf`, `lowercase` and the token pattern live only in the trainer.
// They are reproduced here as a documented, unversioned contract. If the trainer
// ever changes them, nothing in the pack tells us, and this file silently
// becomes wrong. Getting them into the pack is the single highest-value
// hardening left on the contract.

import Foundation

/// scikit-learn `TfidfVectorizer(ngram_range=(1,2), sublinear_tf=True)` +
/// `LogisticRegression`, reproduced for the device.
struct PackTFIDFVectorizer: Sendable {

    /// term → column index in the coefficient matrix.
    let vocabulary: [String: Int]
    /// Inverse document frequency, one per column.
    let idf: [Double]

    init(vocabulary: [String: Int], idf: [Double]) {
        self.vocabulary = vocabulary
        self.idf = idf
    }

    /// Feature width the head expects.
    var dimension: Int { idf.count }

    // MARK: - Tokenisation

    /// sklearn's default `token_pattern = r"(?u)\b\w\w+\b"`.
    ///
    /// Two rules, and the second is the one that bites: split on non-word
    /// characters, then KEEP ONLY tokens of two or more characters. Filtering
    /// happens before n-gram assembly, so dropping a short word joins its
    /// neighbours into a bigram the trainer also produced.
    ///
    /// `\w` in Python's `re` with the UNICODE flag is letters, digits and
    /// underscore — matched here with `isLetter || isNumber || == "_"` rather
    /// than `CharacterSet.alphanumerics`, which is not the same set for
    /// non-Latin scripts and would diverge for a future language pack.
    func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "_" {
                current.append(ch)
            } else if !current.isEmpty {
                if current.count >= 2 { tokens.append(current) }
                current = ""
            }
        }
        if current.count >= 2 { tokens.append(current) }
        return tokens
    }

    /// Unigrams plus adjacent bigrams — `ngram_range=(1, 2)`.
    func features(_ text: String) -> [String] {
        let tokens = tokenize(text)
        guard tokens.count > 1 else { return tokens }
        var out = tokens
        out.reserveCapacity(tokens.count * 2 - 1)
        for i in 0..<(tokens.count - 1) { out.append(tokens[i] + " " + tokens[i + 1]) }
        return out
    }

    // MARK: - Vectorisation

    /// Sublinear TF-IDF, L2-normalised — `sublinear_tf=True`, `norm="l2"`.
    ///
    /// Sublinear means `1 + ln(count)`, not the raw count. With `count == 1`
    /// that is `1 + ln(1) = 1`, so single occurrences weigh exactly their idf.
    ///
    /// Returned sparse: at ~0.1% density a dense 4718-wide array would be
    /// mostly zeros, and the caller needs the dense buffer only when it is
    /// about to hand one to CoreML.
    func vectorize(_ text: String) -> [Int: Double] {
        var counts: [Int: Int] = [:]
        for feature in features(text) {
            if let column = vocabulary[feature] { counts[column, default: 0] += 1 }
        }
        guard !counts.isEmpty else { return [:] }

        var vector: [Int: Double] = [:]
        vector.reserveCapacity(counts.count)
        for (column, count) in counts {
            vector[column] = (1.0 + log(Double(count))) * idf[column]
        }
        let norm = sqrt(vector.values.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.mapValues { $0 / norm }
    }

    /// Dense form, for handing to CoreML.
    func denseVector(_ text: String) -> [Float] {
        var dense = [Float](repeating: 0, count: dimension)
        for (column, value) in vectorize(text) where column < dense.count {
            dense[column] = Float(value)
        }
        return dense
    }

    /// True when nothing in the utterance is in the vocabulary.
    ///
    /// Worth checking explicitly: with an all-zero vector every logit collapses
    /// to its intercept, so argmax becomes a fixed label and softmax returns a
    /// confidence that can clear the 0.70 gate while meaning nothing. Measured
    /// at 5 of 1470 holdout rows (0.34%). A caller must route these to the
    /// out-of-scope intent rather than trusting the score.
    func producesNoFeatures(_ text: String) -> Bool {
        vectorize(text).isEmpty
    }
}
