// PackTextNormalizer.swift
// VoiceAIKit
//
// The surface-form normalisation the TF-IDF model was TRAINED on, ported from
// `nlu_engine/text_norm.py::normalize_text` — the reference's own words:
//
//     `normalize_text()` MUST be applied at every entry point that feeds the
//     English model:
//       * training            (nlu_training/train.py, before fit + ONNX export)
//       * Python inference    (nlu_engine.classifier, the TF-IDF/ONNX path)
//       * on-device / Swift   (port this exact logic for iOS/Android parity)
//
// The third line was never done. The pack has shipped `contractions` since 3.0
// and `lemmas` since pack-en-v1.0.55, `PackLexicon` decoded the first and
// nothing consumed either, so the device fed the head a surface form the head
// was never fitted on. Silent by construction: no crash, no log, just features
// that never match.
//
// WHAT IT COST, measured on pack-en-v1.0.56's own shipped weights against the
// 10,045-row corpus, with `PackTFIDFVectorizer` replicated exactly:
//
//   * PLURAL FOLDING. The trainer folds `memories -> memory` and rebuilds the
//     vocabulary on the folded text, so `memories` is no longer a column at
//     all. Unfolded on device, that feature is simply dropped. Of the 185 rows
//     containing a folded plural, 130 were right where v1.0.54 got 162 — the
//     pack made iOS WORSE by 32 rows, in exactly the family the folding was
//     built to fix:
//         "how do i change memories on my hearing aids?"
//             reference  Help_ChangingMemories 0.983
//             device     Help_DeviceSettings   0.794   (wrong help card)
//         "i'm outdoors now"
//             reference  Cmd.MemoryChange      0.482   (under the gate: nothing)
//             device     Cmd.VolumeUnmute      0.796   (A DEVICE ACTION)
//
//   * THE OOV GUARD, which counts unknown tokens over total and rejects above
//     0.25, was reading inflated ratios for the same reason — an unexpanded
//     contraction is two unknown tokens:
//         "don't mute it"      0.333 -> 0.000
//         "i'm outdoors now"   0.500 -> 0.000
//     Both were being rejected as out-of-vocabulary on device and are not.
//
// SCOPE IS DELIBERATE and mirrors the reference exactly: this runs inside
// `PackTFIDFVectorizer.tokenize`, which serves the TF-IDF path and `oovRatio`
// — the reference's two call sites (`classifier.py:255` and `:339`). The
// keyword stage and the entity extractor match RAW text on both sides, and
// must keep doing so: folding `outdoors -> outdoor` before entity extraction
// would stop the `memory` entity recognising its own value and disarm the
// bare-value guard.
//
// NO REGEX, on purpose. The reference builds one `\b(alt|alt)\b` alternation
// per table, longest-first. ICU's `\b` is not Python's `\b` in every case, and
// this file's whole job is to be identical to Python — so the boundary rule is
// spelled out here against the same `\w` definition `tokenize(_:)` already
// implements, rather than delegated to a second regex dialect. It also keeps
// the type a plain value type, so `PackTFIDFVectorizer` stays `Sendable`
// without an `@unchecked`.
//
// VERIFIED, not asserted: this algorithm was ported back to Python line for
// line and run against `normalize_text` over all 10,045 corpus rows plus 18
// hand-picked edge cases (`reprograms` must NOT fold, `o'clock` -> `oclock`,
// curly apostrophes, repeated whitespace, empty string). 10,063 compared,
// 0 mismatches. The Cowork VM has no Swift toolchain, so that is the strongest
// check available here and it is the one the port is claimed on.

import Foundation

/// `lowercase -> unify apostrophes -> expand contractions -> drop residual
/// apostrophes -> fold plurals -> collapse whitespace`.
///
/// Both tables are pack-owned and per-language (`lexicons/<lang>.json`). Empty
/// tables make the corresponding stage a no-op, so a pack predating either key
/// behaves exactly as this engine did before.
struct PackTextNormalizer: Sendable {

    /// `don't` -> `do not`. Applied BEFORE apostrophes are stripped, which is
    /// the only order that can see the keys.
    private let contractions: Substitutions
    /// `memories` -> `memory`. Applied AFTER expansion and stripping, so it
    /// sees clean word forms — the reference's order, and the reason the
    /// transform stays idempotent.
    private let lemmas: Substitutions

    /// Does nothing. The default everywhere a caller has no lexicon to give,
    /// so an un-updated call site keeps its current behaviour rather than
    /// silently acquiring a half-applied transform.
    static let identity = PackTextNormalizer(contractions: [:], lemmas: [:])

    init(contractions: [String: String], lemmas: [String: String]) {
        self.contractions = Substitutions(contractions)
        self.lemmas = Substitutions(lemmas)
    }

    init(lexicon: PackLexicon) {
        self.init(contractions: lexicon.contractions, lemmas: lexicon.lemmas)
    }

    /// True when neither table has an entry — the caller can then skip the
    /// copy entirely.
    var isIdentity: Bool { contractions.isEmpty && lemmas.isEmpty }

    func normalize(_ text: String) -> String {
        var t = text.lowercased()

        // The three apostrophes a soft keyboard emits, folded to the ASCII one
        // so the contraction table's keys can match. `text_norm._APOSTROPHES`.
        if t.contains("\u{2019}") || t.contains("\u{02BC}") || t.contains("`") {
            t = t.replacingOccurrences(of: "\u{2019}", with: "'")
                 .replacingOccurrences(of: "\u{02BC}", with: "'")
                 .replacingOccurrences(of: "`", with: "'")
        }

        t = contractions.apply(to: t)

        // Residual possessives and `o'clock`. The reference removes rather than
        // splits: `moms reminder`, `oclock`. Both are what the vocabulary holds.
        if t.contains("'") { t = t.replacingOccurrences(of: "'", with: "") }

        t = lemmas.apply(to: t)

        return Self.collapsingWhitespace(t)
    }

    /// `_SPACE_RE.sub(" ", t).strip()`.
    private static func collapsingWhitespace(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false
        for ch in text {
            if ch.isWhitespace {
                if !out.isEmpty { pendingSpace = true }
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(ch)
            }
        }
        return out
    }
}

// MARK: - Whole-word substitution

extension PackTextNormalizer {

    /// One lookup table, applied left to right, longest key first at each
    /// position — the same resolution order as the reference's alternation,
    /// which is built longest-first precisely "so a key that prefixes another
    /// cannot shadow it".
    fileprivate struct Substitutions: Sendable {

        /// Keys grouped by first character, each group longest-first. Without
        /// the bucket every position would try all ~50 English contractions;
        /// with it, only the handful that could possibly start here.
        private let byFirstCharacter: [Character: [(key: [Character], value: String)]]

        var isEmpty: Bool { byFirstCharacter.isEmpty }

        init(_ table: [String: String]) {
            var buckets: [Character: [(key: [Character], value: String)]] = [:]
            for (rawKey, value) in table {
                let key = Array(rawKey.lowercased())
                guard let first = key.first else { continue }
                buckets[first, default: []].append((key, value))
            }
            // Longest first; the key itself breaks ties so the table's ordering
            // — which a Dictionary does not have — cannot change the output.
            //
            // Over a COPY of the keys: `buckets.keys` is a view onto `buckets`,
            // and mutating the dictionary while iterating it is an exclusivity
            // violation.
            for first in Array(buckets.keys) {
                buckets[first]?.sort {
                    $0.key.count != $1.key.count
                        ? $0.key.count > $1.key.count
                        : String($0.key) < String($1.key)
                }
            }
            self.byFirstCharacter = buckets
        }

        /// `\w` as `tokenize(_:)` defines it: letters, digits and underscore.
        /// Anything else is a boundary.
        private static func isWordCharacter(_ ch: Character) -> Bool {
            ch.isLetter || ch.isNumber || ch == "_"
        }

        func apply(to text: String) -> String {
            guard !byFirstCharacter.isEmpty else { return text }
            let chars = Array(text)
            var out = ""
            out.reserveCapacity(chars.count)
            var i = 0
            while i < chars.count {
                // A key may only start where a word starts — `\b` before the
                // first character. Without this, "programs" inside "reprograms"
                // would be folded.
                let atWordStart = Self.isWordCharacter(chars[i])
                    && (i == 0 || !Self.isWordCharacter(chars[i - 1]))

                if atWordStart, let candidates = byFirstCharacter[chars[i]] {
                    var replaced = false
                    for candidate in candidates {
                        let end = i + candidate.key.count
                        guard end <= chars.count else { continue }
                        var k = 0
                        while k < candidate.key.count, chars[i + k] == candidate.key[k] {
                            k += 1
                        }
                        guard k == candidate.key.count else { continue }
                        // `\b` after the last character too — but only when the
                        // key ENDS in a word character. A key ending in "'" or
                        // "." already sits on a boundary, which is how the
                        // reference's `\b` behaves for the same key.
                        if let last = candidate.key.last, Self.isWordCharacter(last),
                           end < chars.count, Self.isWordCharacter(chars[end]) {
                            continue
                        }
                        out += candidate.value
                        i = end
                        replaced = true
                        break
                    }
                    if replaced { continue }
                }

                out.append(chars[i])
                i += 1
            }
            return out
        }
    }
}
