// PackTFIDFVectorizer.swift
// VoiceAIKit
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

    /// The single-word terms only. Bigram keys carry a space, so they are the
    /// ones excluded — the OOV guard asks "can the featurizer represent this
    /// WORD?", and a bigram is not an answer to that. Precomputed because the
    /// guard runs on every turn and the vocabulary is up to 4718 entries.
    let unigrams: Set<String>

    /// The surface-form transform the head was FITTED on — contraction
    /// expansion, apostrophe removal, plural folding. See
    /// `PackTextNormalizer`.
    ///
    /// Defaulted to `.identity` so the existing construction sites, including
    /// the test doubles, keep compiling and keep their current behaviour. A
    /// caller that has the pack's lexicon must pass it: an empty table is not
    /// "no normalisation is needed", it is "this pack declares none".
    let normalizer: PackTextNormalizer

    init(vocabulary: [String: Int], idf: [Double],
         normalizer: PackTextNormalizer = .identity) {
        self.vocabulary = vocabulary
        self.idf = idf
        self.normalizer = normalizer
        var single = Set<String>()
        single.reserveCapacity(vocabulary.count)
        for term in vocabulary.keys where !term.contains(" ") { single.insert(term) }
        self.unigrams = single
    }

    /// Share of this utterance's tokens the featurizer cannot represent.
    ///
    /// A token outside the vocabulary is not weighed and dismissed — there is no
    /// column to put it in, so the sentence reaches the model without it:
    ///
    ///     "turn off"          -> 3 non-zero features
    ///     "turn off toshiba"  -> 3 non-zero features, cosine 1.000000
    ///
    /// The two vectors are bit-identical, so no threshold or training row can
    /// separate them: the model is never asked the question. And the word that
    /// puts an utterance out of scope is almost always a rare, specific one — a
    /// brand, an object, a topic — exactly what a finite vocabulary lacks.
    ///
    /// Mirrors the reference `IntentClassifier.oov_ratio`, which tokenises with
    /// `(?u)\b\w\w+\b` — the same rule `tokenize(_:)` implements — and counts
    /// against the model's UNIGRAM vocabulary.
    ///
    /// Returns 0 when there is no vocabulary or no token, which DISABLES the
    /// guard rather than rejecting everything. The reference does the same.
    func oovRatio(_ text: String) -> Double {
        guard !unigrams.isEmpty else { return 0 }
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return 0 }
        var unknown = 0
        for token in tokens where !unigrams.contains(token) { unknown += 1 }
        return Double(unknown) / Double(tokens.count)
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
    /// Normalises FIRST, then tokenises — the reference's order at both of its
    /// call sites (`classifier.py:255` feeds `tfidf_logits(normalize_text(t))`,
    /// and `:339` computes the OOV tokens from `normalize_text(t)`). Because
    /// every entry point of this type funnels through here, `oovRatio`,
    /// `vectorize`, `featureCount` and `producesNoFeatures` all inherit it and
    /// cannot drift apart.
    ///
    /// The keyword stage and the entity extractor do NOT come through here and
    /// must not: both match raw text on the reference side too, and folding
    /// `outdoors -> outdoor` before entity extraction would stop the `memory`
    /// entity recognising its own value.
    func tokenize(_ text: String) -> [String] {
        let normalized = normalizer.isIdentity ? text : normalizer.normalize(text)
        var tokens: [String] = []
        var current = ""
        for ch in normalized.lowercased() {
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

    /// How many non-zero features this utterance produces — the width of the
    /// evidence the head actually scores on.
    ///
    /// Observability, not policy: nothing in the decision path reads this. It
    /// exists because a one-feature vector and a ten-feature vector are
    /// indistinguishable downstream — both arrive as a confidence — and a
    /// one-feature vector saturates the softmax, so degeneracy reads as
    /// certainty. Every audit of that behaviour so far had to reconstruct this
    /// number outside the app.
    ///
    /// `vectorize(_:)` already computes it and discards it; this is the same
    /// count, recomputed rather than cached, because no hot path calls it.
    func featureCount(_ text: String) -> Int { vectorize(text).count }

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
