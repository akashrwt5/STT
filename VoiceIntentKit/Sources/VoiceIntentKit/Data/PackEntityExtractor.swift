// PackEntityExtractor.swift
// VoiceIntentKit
//
// Resolves gazetteer ("enum") entities — memory names, recurrence, reminder
// subjects — from a `ResolvedPack`. Datetime lives in `PackDateTimeParser`.
//
// Replaces the enum half of `EntityExtractor`, which read `nlu_entities.json`
// out of `Bundle.module`. Values here are already language-resolved by the
// loader, so nothing in this file knows what language it is working in.
//
// A WARNING ABOUT THE FUZZY RULES
// The pack declares `"fuzzy": true` on an entity and NOTHING else — no
// algorithm, no distance metric, no threshold, no minimum length, no stopword
// list. Every one of those lives only in the Python engine
// (`packages/runtime/nlu_engine/entities.py::extract_enum`), and each is
// reproduced here by hand so the two runtimes agree.
//
// That makes this file an UNVERSIONED CONTRACT. If the reference changes its
// edit-distance ratio or its stopwords, nothing in the pack tells us, and a
// device will silently resolve slots differently from the server that trained
// the model. Getting these parameters into the pack is tracked as a contract
// request; until then, treat this file as coupled to that Python function and
// change them together.

import Foundation
import os.log

struct PackEntityExtractor: Sendable {

    // MARK: - Result

    struct Match: Sendable, Equatable {
        /// The canonical value, not the surface form that matched.
        let value: String
        /// The text that matched, for highlighting and telemetry.
        let span: String
        /// 1.00 exact/canonical · 0.95 synonym · 0.60–0.90 fuzzy.
        let confidence: Double
        let isFuzzy: Bool
    }

    // MARK: - Reference constants
    //
    // Mirrored from extract_enum. Named rather than inlined so a divergence
    // shows up as a changed constant instead of a changed expression.

    /// Synonyms shorter than this are never fuzzy candidates. Short memory names
    /// (Car, Gym, Pub, Mute, one…) sit within one edit of common words, so
    /// fuzzy-matching them selects the wrong memory. Exact matching still works
    /// for them — only the approximate path is length-gated.
    static let fuzzyMinimumLength = 5

    /// Allowed edits, as a fraction of the synonym's length.
    static let fuzzyDistanceRatio = 0.3

    static let fuzzyConfidenceFloor = 0.60
    static let fuzzyConfidenceCeiling = 0.90

    /// Function words that are never treated as typos.
    ///
    /// "the" is not a misspelling of the memory "three" — it is a different word
    /// that happens to be two edits away. Without this list an off-topic
    /// sentence ("who is the prime minister of india") fuzzy-matched an enum
    /// value through a stopword and silently filled a slot.
    // MARK: - State

    /// entity id → lowercased surface form → canonical value.
    private let tables: [String: [String: String]]
    /// entity id → whether approximate matching is permitted.
    private let fuzzyEnabled: [String: Bool]
    /// Entities the host must resolve (`sys.date_time`, `sys.number_integer`).
    let dynamicEntities: Set<String>
    /// Entities whose gazetteer is a hint rather than a closed set, so a free-text
    /// answer is acceptable. **Not in the v3 surface** — see `openEntities` on the
    /// initialiser and VIK-017.
    private let openEntities: Set<String>
    private let stopwords: Set<String>
    private let log: Logger

    // MARK: - Init

    /// - Parameter stopwords: words excluded as typo candidates. Defaults to the
    ///   PACK's own `lexicon.fuzzyStopwords`, so each language ships its own list
    ///   and a non-English pack needs no code change. Pass a value only to
    ///   override the pack.
    ///
    ///   It used to default to EMPTY, and that was a trap. The list is what stops
    ///   "the" fuzzy-matching the memory "three" (VIK-007); an empty default meant
    ///   every caller that did not think to pass one silently lost the guard, and
    ///   the only symptom is a wrong slot filled with confidence 0.60. Production
    ///   passed one through `PackEngineFactory`; the test suite did not, and spent
    ///   the difference proving the guard was broken when it was not.
    /// - Parameter openEntities: entities whose value list is a hint, not a
    ///   closed set. Comes from `ResolvedPack.openEntities`, which the compiler
    ///   now emits (VIK-017) — callers should not be assembling this by hand.
    ///   Absent it, an entity like `remind` looks closed, a slot answer outside
    ///   the gazetteer is rejected, and "remind me to buy milk" cannot fill its
    ///   own name slot; the symptom is a re-prompt, never an error.
    init(pack: ResolvedPack,
                stopwords: Set<String>? = nil,
                openEntities: Set<String> = []) {
        var tables: [String: [String: String]] = [:]
        var fuzzy: [String: Bool] = [:]

        for (entityID, values) in pack.entities {
            var table: [String: String] = [:]
            for (canonical, synonyms) in values {
                // The canonical value is itself matchable — that is what makes
                // an exact match score 1.00 rather than 0.95.
                table[canonical.lowercased()] = canonical
                for synonym in synonyms { table[synonym.lowercased()] = canonical }
            }
            tables[entityID] = table
            fuzzy[entityID] = pack.fuzzyEntities.contains(entityID)
        }

        self.tables = tables
        self.fuzzyEnabled = fuzzy
        self.dynamicEntities = pack.dynamicEntities
        self.openEntities = openEntities
        self.stopwords = stopwords ?? Set(pack.lexicon.fuzzyStopwords ?? [])
        self.log = Logger(subsystem: "com.voiceintentkit", category: "EntityExtractor")
    }

    /// Designated initialiser for callers that know an entity's fuzzy flag —
    /// the loader strips `EntityDefinition` down to synonyms, so the flag has to
    /// be threaded in separately.
    init(tables: [String: [String: String]],
                fuzzyEnabled: [String: Bool],
                dynamicEntities: Set<String>,
                stopwords: Set<String>,
                openEntities: Set<String> = []) {
        self.tables = tables
        self.fuzzyEnabled = fuzzyEnabled
        self.dynamicEntities = dynamicEntities
        self.openEntities = openEntities
        self.stopwords = stopwords
        self.log = Logger(subsystem: "com.voiceintentkit", category: "EntityExtractor")
    }

    // MARK: - Extraction

    /// Resolve `entity` from `text`.
    ///
    /// - Parameter allowFuzzy: pass `false` when scanning a whole utterance
    ///   speculatively. A stray fuzzy hit on a common word is a wrong-action
    ///   risk; approximate matching is for answers to an explicit slot prompt,
    ///   where the user is already talking about that slot.
    func extract(_ entity: String, from text: String, allowFuzzy: Bool = true) -> Match? {
        guard let table = tables[entity], !table.isEmpty else { return nil }
        let haystack = text.lowercased()

        // Exact and synonym, longest surface form first so a multi-word value
        // is not pre-empted by a substring of itself.
        let surfaces = table.keys.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
        }
        for surface in surfaces where Self.containsWord(surface, in: haystack) {
            guard let canonical = table[surface] else { continue }
            let isCanonical = surface == canonical.lowercased()
            return Match(value: canonical,
                         span: surface,
                         confidence: isCanonical ? 1.00 : 0.95,
                         isFuzzy: false)
        }

        guard allowFuzzy, fuzzyEnabled[entity] == true else { return nil }
        return fuzzyMatch(in: haystack, table: table)
    }

    /// True when the entity is resolved by the host at match time rather than
    /// from a gazetteer.
    func isDynamic(_ entity: String) -> Bool { dynamicEntities.contains(entity) }

    /// Entities whose value list is open-ended, so a free-text answer is
    /// acceptable.
    ///
    /// A dynamic entity is NOT open. It has no table, so the previous
    /// "absent from `tables`" rule reported `sys.date_time` as open — and the
    /// engine's `fillOpenTopics` then wrote the derived free-text topic
    /// ("buy milk") straight into the date-time slot, satisfying it with a
    /// string that is not a date. The doc comment said "and not dynamic"; the
    /// code did not. Order matters here, not just the predicate.
    func isOpen(_ entity: String) -> Bool {
        if dynamicEntities.contains(entity) { return false }
        if openEntities.contains(entity) { return true }
        return tables[entity]?.isEmpty ?? true
    }

    // MARK: - Fuzzy

    private func fuzzyMatch(in haystack: String, table: [String: String]) -> Match? {
        let tokens = Self.tokens(in: haystack).filter { !stopwords.contains($0) }
        guard !tokens.isEmpty else { return nil }

        var bestValue: String?
        var bestSpan = ""
        var bestDistance = Int.max
        var bestLength = 1

        for (surface, canonical) in table {
            // Multi-word synonyms are excluded: edit distance across a phrase
            // is dominated by word order, not spelling.
            if surface.contains(" ") { continue }
            if surface.count < Self.fuzzyMinimumLength { continue }

            let limit = max(1, Int((Double(surface.count) * Self.fuzzyDistanceRatio).rounded()))
            for token in tokens {
                // Cheap length pre-filter before the O(n·m) distance.
                if abs(token.count - surface.count) > limit { continue }
                let distance = Self.levenshtein(token, surface)
                if distance <= limit && distance < bestDistance {
                    bestValue = canonical
                    bestSpan = token
                    bestDistance = distance
                    bestLength = surface.count
                }
            }
        }

        guard let value = bestValue else { return nil }
        // Scales from 0.90 at one edit down to 0.60 at the limit.
        // Mirrors `round(1.0 - best_d / best_len, 2)` — the ×100/÷100 is the
        // 2-decimal rounding, so it must wrap the WHOLE subtraction. Applying it
        // to the ratio alone (an easy slip) yields values in the hundreds, which
        // the clamp then silently flattens to 0.90 for every fuzzy hit.
        let ratio = Double(bestDistance) / Double(bestLength)
        let raw = ((1.0 - ratio) * 100).rounded() / 100
        let confidence = min(Self.fuzzyConfidenceCeiling, max(Self.fuzzyConfidenceFloor, raw))
        return Match(value: value, span: bestSpan, confidence: confidence, isFuzzy: true)
    }

    // MARK: - Text helpers

    /// Word-boundary containment, matching Python's `\b…\b`.
    static func containsWord(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            let leftOK = found.lowerBound == haystack.startIndex
                || !isWordCharacter(haystack[haystack.index(before: found.lowerBound)])
            let rightOK = found.upperBound == haystack.endIndex
                || !isWordCharacter(haystack[found.upperBound])
            if leftOK && rightOK { return true }
            guard found.upperBound < haystack.endIndex else { return false }
            searchRange = haystack.index(after: found.lowerBound)..<haystack.endIndex
        }
        return false
    }

    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// Alphanumeric runs, matching the reference's `[a-z0-9]+` over lowered text.
    static func tokens(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Classic Levenshtein, two-row. Matches the reference implementation.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let lhs = Array(a), rhs = Array(b)
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
