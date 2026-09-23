// PackSlotTagger.swift
// VoiceAIKit
//
// The BIO slot tagger: utterance in, open-slot title out ("please remind me to
// take my medicine tomorrow at 5 pm" -> "take my medicine").
//
// WHY NOT CORE ML. The model is a multinomial logistic regression over ~2,700
// sparse, string-named features and three classes (B-TITLE / I-TITLE / O).
// Scoring one token is ~30 dictionary lookups; there is nothing for Core ML to
// accelerate. Almost all of the work is text feature extraction (regex
// preprocessing, tokenising, affixes, trigger distance), which Swift has to do
// either way. And the parity fixture's tightest margin is 0.0425 — close enough
// that fp16 execution on the ANE/GPU could flip a tag.
//
// ONE ARTIFACT, THREE RUNTIMES. This scores `slot_tagger_weights.json`, the same
// file Android's `NluSlotTagger` scores and the same file the Python reference
// `nlu_engine.slot_tagger.JsonSlotTagger` scores. That reference is the oracle:
// `SlotTaggerParityTests` replays its 250-row fixture through this type and
// every token, tag and title must match.
//
// NO ENGLISH HERE. Every regex, word list, size and label name comes from the
// `feature_spec` embedded in the weights file. A new language is a pack update.
//
// Where a naive port silently disagrees with Python — each handled below:
//
//   1. `rel_pos` rounding. Python's `round()` rounds the EXACT binary value,
//      half-to-even; Swift's `.rounded()` is half-away-from-zero. See
//      `roundLikePython`.
//   2. Case-insensitive preprocessing. Python compiles with `re.I`; the spec
//      carries no flag, so `.caseInsensitive` is applied here to match.
//   3. Length and affixes count CODE POINTS in Python. `String.count` and
//      `prefix`/`suffix` count grapheme clusters, which differ for combining
//      marks and emoji — so this type works on `unicodeScalars`.
//   4. `isdigit`. Python's `str.isdigit()` is Numeric_Type Digit or Decimal;
//      `isPythonDigit` asks the same Unicode property.
//   5. Arg-max ties go to the LOWEST class index, as `numpy.argmax` does. A
//      strict `>` scanning left to right gives that; `>=` does not.

import Foundation

// MARK: - The engine's view

/// Reads the title of an open free-text slot out of an utterance.
///
/// The engine depends on this, not on `PackSlotTagger`, for the same reason it
/// depends on `SlotResolving`: where the answer comes from can change without
/// touching the dialog logic, and tests can inject a fixed answer.
protocol OpenSlotTitleExtracting: Sendable {
    /// The title, or nil when the utterance names no subject ("create a
    /// reminder", "set an alarm for 8 a.m."). Nil is an answer, not a failure.
    func title(of text: String) -> String?
}

// MARK: - Tagger

/// Immutable after `init`, so one instance is shared across queues.
///
/// A final class marked `@unchecked Sendable` rather than a struct because it
/// holds `NSRegularExpression`s. Every stored property is a `let`, nothing is
/// mutated after `init`, and `NSRegularExpression` is documented as immutable
/// and safe to use from multiple threads.
final class PackSlotTagger: OpenSlotTitleExtracting, @unchecked Sendable {

    /// The `feature_spec.version` this implementation reproduces. A different
    /// version redefines features (v3 changes `rel_pos` and the tokenizer), so
    /// scoring it with these rules would be silently wrong.
    static let supportedFeatureSpecVersion = 2

    let classes: [String]
    let featureSpecVersion: Int
    private let intercept: [Double]
    private let weights: [String: [Double]]

    private let preprocessRules: [(regex: NSRegularExpression, template: String)]
    private let whitespace: NSRegularExpression
    private let tokenizer: NSRegularExpression
    private let affixSizes: [Int]
    private let neighbourSuffix: Int
    private let relPosDecimals: Int
    private let triggerWords: Set<String>
    private let triggerWindow: Int
    private let prepositions: Set<String>
    private let timeWords: Set<String>
    private let begin: String
    private let inside: String

    // MARK: Init

    enum LoadError: Error, Equatable {
        /// The file is not the shape the exporter writes, or its numbers do not
        /// line up (a weights row shorter than the class list would crash at
        /// the first unlucky token, so it is refused here instead).
        case malformed(String)
        /// Well-formed, but for a `feature_spec` this build cannot reproduce.
        case unsupportedFeatureSpec(found: Int, supported: Int)
    }

    /// Mirrors `export_slot_weights.py`'s payload. Strict: a missing key is an
    /// error, never a default — the port this replaces defaulted every spec
    /// field, which would score a truncated file with invented rules.
    private struct Payload: Decodable {
        let classes: [String]
        let intercept: [Double]
        let weights: [String: [Double]]
        let featureSpec: Spec

        enum CodingKeys: String, CodingKey {
            case classes, intercept, weights
            case featureSpec = "feature_spec"
        }

        struct Spec: Decodable {
            let version: Int
            let preprocess: [[String]]
            let tokenizer: String
            let affixSizes: [Int]
            let neighbourSuffix: Int
            let relPosDecimals: Int
            let triggerWords: [String]
            let triggerWindow: Int
            let prepositions: [String]
            let timeWords: [String]
            let labels: [String: String]

            enum CodingKeys: String, CodingKey {
                case version, preprocess, tokenizer, prepositions, labels
                case affixSizes = "affix_sizes"
                case neighbourSuffix = "neighbour_suffix"
                case relPosDecimals = "rel_pos_decimals"
                case triggerWords = "trigger_words"
                case triggerWindow = "trigger_window"
                case timeWords = "time_words"
            }
        }
    }

    convenience init(contentsOf url: URL) throws {
        try self.init(weightsJSON: try Data(contentsOf: url))
    }

    init(weightsJSON data: Data) throws {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw LoadError.malformed(String(describing: error))
        }
        let spec = payload.featureSpec

        guard spec.version == Self.supportedFeatureSpecVersion else {
            throw LoadError.unsupportedFeatureSpec(found: spec.version,
                                                   supported: Self.supportedFeatureSpecVersion)
        }

        // -- shapes -------------------------------------------------------
        guard payload.classes.count >= 2 else {
            throw LoadError.malformed("need at least 2 classes, found \(payload.classes.count)")
        }
        guard payload.intercept.count == payload.classes.count else {
            throw LoadError.malformed(
                "intercept has \(payload.intercept.count) values for \(payload.classes.count) classes")
        }
        for (feature, row) in payload.weights where row.count != payload.classes.count {
            throw LoadError.malformed(
                "weights['\(feature)'] has \(row.count) values for \(payload.classes.count) classes")
        }
        guard let begin = spec.labels["begin"], let inside = spec.labels["inside"] else {
            throw LoadError.malformed("feature_spec.labels needs 'begin' and 'inside'")
        }
        guard payload.classes.contains(begin), payload.classes.contains(inside) else {
            throw LoadError.malformed("labels '\(begin)'/'\(inside)' are not in classes \(payload.classes)")
        }
        guard spec.neighbourSuffix > 0, spec.relPosDecimals >= 0,
              spec.affixSizes.allSatisfy({ $0 > 0 }) else {
            throw LoadError.malformed("feature_spec sizes must be positive")
        }

        // -- regexes --------------------------------------------------------
        var rules: [(regex: NSRegularExpression, template: String)] = []
        for (index, pair) in spec.preprocess.enumerated() {
            guard pair.count == 2 else {
                throw LoadError.malformed("preprocess[\(index)] is not a [pattern, replacement] pair")
            }
            do {
                // `.caseInsensitive` mirrors Python's `re.I`. No
                // `.dotMatchesLineSeparators`: utterances are single-line.
                let regex = try NSRegularExpression(pattern: pair[0], options: [.caseInsensitive])
                rules.append((regex: regex, template: pair[1]))
            } catch {
                throw LoadError.malformed("preprocess[\(index)] does not compile: \(pair[0])")
            }
        }
        do {
            self.tokenizer = try NSRegularExpression(pattern: spec.tokenizer, options: [])
            self.whitespace = try NSRegularExpression(pattern: "\\s+", options: [])
        } catch {
            throw LoadError.malformed("tokenizer does not compile: \(spec.tokenizer)")
        }

        self.classes = payload.classes
        self.featureSpecVersion = spec.version
        self.intercept = payload.intercept
        self.weights = payload.weights
        self.preprocessRules = rules
        self.affixSizes = spec.affixSizes
        self.neighbourSuffix = spec.neighbourSuffix
        self.relPosDecimals = spec.relPosDecimals
        self.triggerWords = Set(spec.triggerWords)
        self.triggerWindow = spec.triggerWindow
        self.prepositions = Set(spec.prepositions)
        self.timeWords = Set(spec.timeWords)
        self.begin = begin
        self.inside = inside
    }

    // MARK: Public surface

    /// Utterance in, title out — or nil when the utterance carries no subject.
    func title(of text: String) -> String? {
        let tokens = prepare(text)
        guard !tokens.isEmpty else { return nil }
        return titleSpan(tokens, tag(tokens))
    }

    // MARK: Text -> tokens

    /// Every `preprocess` rule in spec order, then whitespace collapsed and
    /// trimmed. A later rule reads the earlier rules' output, so order matters.
    func preprocess(_ text: String) -> String {
        var current = text
        for rule in preprocessRules {
            current = rule.regex.stringByReplacingMatches(
                in: current, options: [], range: Self.fullRange(current),
                withTemplate: rule.template)
        }
        current = whitespace.stringByReplacingMatches(
            in: current, options: [], range: Self.fullRange(current), withTemplate: " ")
        return current.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func tokenize(_ text: String) -> [String] {
        tokenizer.matches(in: text, options: [], range: Self.fullRange(text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// Preprocess then tokenise. Training and every runtime go through this.
    func prepare(_ text: String) -> [String] {
        tokenize(preprocess(text))
    }

    // MARK: Tokens -> features

    /// Token `i`'s features, already flattened to (column, value) pairs.
    ///
    /// Flattening is `DictVectorizer`'s rule: a string becomes the one-hot
    /// column `"key=value"` valued 1, a bool becomes `"key"` valued 1 or 0, a
    /// number becomes `"key"` valued as itself. The ORDER is the reference's.
    /// It does not change the arg-max, but keeping it identical makes floating-
    /// point accumulation identical, so a parity failure is always a real one.
    func features(_ tokens: [String], _ i: Int) -> [(String, Double)] {
        let low = tokens[i].lowercased()

        var nearest = 99
        for (index, token) in tokens.enumerated() where triggerWords.contains(token.lowercased()) {
            let distance = i - index
            if distance > 0 && distance < nearest { nearest = distance }
        }

        var out: [(String, Double)] = [
            ("bias", 1.0),
            ("word.lower()=\(low)", 1.0),
            ("len", Double(low.unicodeScalars.count)),
            ("isdigit", Self.isPythonDigit(tokens[i]) ? 1.0 : 0.0),
            ("after_trigger", nearest < triggerWindow ? 1.0 : 0.0),
            ("rel_pos", roundLikePython(Double(i) / Double(max(tokens.count, 1)), relPosDecimals)),
        ]
        for size in affixSizes {
            out.append(("p\(size)=\(Self.scalarPrefix(low, size))", 1.0))
            out.append(("s\(size)=\(Self.scalarSuffix(low, size))", 1.0))
        }
        if i > 0 {
            let prev = tokens[i - 1].lowercased()
            out.append(("-1:w=\(prev)", 1.0))
            out.append(("-1:s\(neighbourSuffix)=\(Self.scalarSuffix(prev, neighbourSuffix))", 1.0))
            out.append(("-1:is_prep", prepositions.contains(prev) ? 1.0 : 0.0))
        } else {
            out.append(("BOS", 1.0))
        }
        if i < tokens.count - 1 {
            let next = tokens[i + 1].lowercased()
            out.append(("+1:w=\(next)", 1.0))
            out.append(("+1:s\(neighbourSuffix)=\(Self.scalarSuffix(next, neighbourSuffix))", 1.0))
            out.append(("+1:is_time", timeWords.contains(next) ? 1.0 : 0.0))
        } else {
            out.append(("EOS", 1.0))
        }
        return out
    }

    // MARK: Features -> tags

    func scores(_ tokens: [String], _ i: Int) -> [Double] {
        var totals = intercept
        for (key, value) in features(tokens, i) {
            if value == 0.0 { continue }
            // An unseen feature has no column; sklearn drops it too.
            guard let row = weights[key] else { continue }
            for index in 0..<totals.count { totals[index] += row[index] * value }
        }
        return totals
    }

    /// Ties go to the LOWEST class index (`numpy.argmax`). Do not "tidy" the
    /// strict `>` into `>=`.
    func tag(_ tokens: [String]) -> [String] {
        var tags: [String] = []
        tags.reserveCapacity(tokens.count)
        for i in 0..<tokens.count {
            let s = scores(tokens, i)
            var best = 0
            for index in 1..<s.count where s[index] > s[best] { best = index }
            tags.append(classes[best])
        }
        return tags
    }

    /// Top-1 minus top-2 per token. A near-zero margin is where runtimes can
    /// legitimately diverge; the parity test reports the smallest one it passed.
    func margins(_ tokens: [String]) -> [Double] {
        (0..<tokens.count).map { i in
            let ordered = scores(tokens, i).sorted(by: >)
            return ordered[0] - ordered[1]
        }
    }

    /// The one BIO decoding rule: the LAST complete B-/I- run wins, and an `I-`
    /// with no `B-` in front of it does not open a span. The trainer, the Python
    /// runtime, Android and this share it.
    func titleSpan(_ tokens: [String], _ tags: [String]) -> String? {
        var found: String?
        var buffer: [String] = []
        for (token, tag) in zip(tokens, tags) {
            if tag == begin {
                if !buffer.isEmpty { found = buffer.joined(separator: " ") }
                buffer = [token]
            } else if tag == inside && !buffer.isEmpty {
                buffer.append(token)
            } else if !buffer.isEmpty {
                found = buffer.joined(separator: " ")
                buffer = []
            }
        }
        if !buffer.isEmpty { found = buffer.joined(separator: " ") }
        return found
    }

    // MARK: Primitives

    private static func fullRange(_ s: String) -> NSRange {
        NSRange(s.startIndex..., in: s)
    }

    /// Python's `str.isdigit()`: non-empty, every code point Numeric_Type
    /// Digit or Decimal.
    static func isPythonDigit(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy {
            $0.properties.numericType == .decimal || $0.properties.numericType == .digit
        }
    }

    /// `s[:n]` in Python — code points, not grapheme clusters.
    static func scalarPrefix(_ s: String, _ n: Int) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s.unicodeScalars.prefix(n))
        return String(view)
    }

    /// `s[-n:]` in Python — code points, not grapheme clusters.
    static func scalarSuffix(_ s: String, _ n: Int) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s.unicodeScalars.suffix(n))
        return String(view)
    }
}

// MARK: - Python's round()

/// Python's `round(x, digits)`: round the EXACT value of the double to `digits`
/// decimal places, breaking a genuine tie toward the even digit.
///
/// Swift's `.rounded()` breaks ties away from zero, so 1/4 gives 0.3 instead of
/// Python's 0.2. `%.20f` prints the correctly-rounded exact expansion, which
/// separates a true tie (0.25, exactly representable) from a value that only
/// looks like one (0.35 is 0.34999999999999997779… and rounds down).
///
/// The algorithm was checked against Python's `round(i / n, 1)` for every
/// 0 <= i < n < 400 (79,800 pairs, zero mismatches).
func roundLikePython(_ value: Double, _ digits: Int) -> Double {
    guard value.isFinite else { return value }
    let text = String(format: "%.20f", value)
    let parts = text.split(separator: ".", maxSplits: 1)
    guard parts.count == 2 else { return value }
    let whole = Array(parts[0])
    var frac = Array(parts[1])
    while frac.count <= digits { frac.append("0") }

    let keep = Array(frac[0..<digits])
    let rest = Array(frac[digits...])
    let firstDropped = rest[0]
    let remainderIsZero = rest.dropFirst().allSatisfy { $0 == "0" }

    let roundUp: Bool
    if firstDropped > "5" {
        roundUp = true
    } else if firstDropped < "5" {
        roundUp = false
    } else if !remainderIsZero {
        roundUp = true                                  // above the tie
    } else {
        let last = keep.last ?? whole.last ?? "0"       // exact tie: to even
        roundUp = ((last.wholeNumberValue ?? 0) % 2) != 0
    }

    var digitsOut = whole.filter { $0 != "-" } + keep
    if roundUp {
        var index = digitsOut.count - 1
        while index >= 0 {
            if digitsOut[index] == "9" {
                digitsOut[index] = "0"
                index -= 1
            } else {
                digitsOut[index] = Character(String((digitsOut[index].wholeNumberValue ?? 0) + 1))
                break
            }
        }
        if index < 0 { digitsOut.insert("1", at: 0) }
    }

    let split = digitsOut.count - digits
    let intPart = String(digitsOut[0..<split])
    let fracPart = String(digitsOut[split...])
    let sign = value < 0 ? "-" : ""
    return Double("\(sign)\(intPart.isEmpty ? "0" : intPart).\(fracPart.isEmpty ? "0" : fracPart)")
        ?? value
}
