// PackSlotResolver.swift
// VoiceIntentKit
//
// The five questions `NLUEngine` asks about a slot, and a pack-driven answer to
// each.
//
// The engine used to hold a concrete `EntityExtractor`, which reads
// `nlu_entities.json` from a URL and falls back to `Bundle.module` when that URL
// is nil. That is why the package still ships 29 MB of resources: not because
// the engine needs a file, but because the type it depends on cannot be built
// without one. Bridging a pack onto that signature would mean writing the pack's
// entity tables back out to a temporary JSON — worse than the problem.
//
// So the dependency is stated as what the engine actually needs. Five methods,
// no file, no bundle. `PackSlotResolver` answers them from a `ResolvedPack`;
// `EntityExtractor` answers them from its file (see
// `EntityExtractor+SlotResolving.swift`) until step 3 deletes it. The engine's
// 469 lines of dialog logic are unchanged either way, which is the point —
// changing where data comes from and rewriting confirmation/slot-filling
// behaviour at the same time is how you lose the ability to tell which one
// broke.

import Foundation
import os.log

// MARK: - Result

/// A resolved date-time, in the shape the engine stores in a slot.
///
/// Local wall-clock ISO (`yyyy-MM-dd'T'HH:mm`, no zone) rather than a `Date`
/// because slot values are `[String: String]` and the engine round-trips the
/// parked day through this exact format. Handing it a `Date` would move that
/// formatting into the engine, which is where it should NOT be — the parser owns
/// the calendar and the time zone.
struct SlotDateTime: Sendable, Equatable {

    /// `yyyy-MM-dd'T'HH:mm` in the resolver's time zone.
    let iso: String

    /// True when the user actually said a time. False means only a day was
    /// given and the hour was defaulted — the engine parks the day and prompts
    /// for the hour rather than committing a time nobody asked for.
    let timeExplicit: Bool

    /// True when the user named a day. The engine must not anchor an answer that
    /// carries its own day onto a previously parked one, or the day advances
    /// twice.
    let explicitDay: Bool

    init(iso: String, timeExplicit: Bool, explicitDay: Bool) {
        self.iso = iso
        self.timeExplicit = timeExplicit
        self.explicitDay = explicitDay
    }
}

// MARK: - Contract

/// What `NLUEngine` needs to know about a slot's entity.
protocol SlotResolving: Sendable {

    /// True when this entity is resolved by parsing a date-time rather than by
    /// looking a value up.
    ///
    /// Asked rather than compared against a literal. The engine previously
    /// tested `slot.entity == "sys.date-time"`, spelled with a HYPHEN — which is
    /// the flattened root shim's spelling. The v3 surface the pack loader binds
    /// to spells it `sys.date_time`, with an underscore, so once a pack drove
    /// the engine that comparison could never be true and every date-time slot
    /// silently took the gazetteer path instead. See VIK-018.
    func isDateTime(_ entity: String) -> Bool

    /// True when the entity's value list is a hint rather than a closed set, so
    /// a free-text answer is acceptable.
    func isOpen(_ entity: String) -> Bool

    /// Resolve `entity` from `text`, or nil.
    ///
    /// - Parameter isDirectAnswer: true when `text` is the user's reply to an
    ///   explicit prompt for THIS slot, false when the engine is scanning a
    ///   whole utterance speculatively for any slot it can fill. Approximate
    ///   matching is only safe in the first case: a stray fuzzy hit on a common
    ///   word in an unrelated sentence fills a slot the user never mentioned,
    ///   and the resulting wrong action is not traceable to a spelling guess.
    func extract(_ entity: String, from text: String, isDirectAnswer: Bool) -> String?

    /// Resolve a date-time from `text`, relative to `now`.
    func dateTime(in text: String, now: Date) -> SlotDateTime?

    /// Remove date/time fragments so what remains can serve as a free-text topic.
    func strippingDateTime(_ text: String) -> String
}

// MARK: - Pack-driven implementation

struct PackSlotResolver: SlotResolving {

    private let entities: PackEntityExtractor
    private let datetime: PackDateTimeParser
    private let dateTimeEntities: Set<String>
    private let timeZone: TimeZone

    /// The `dynamic_source` this runtime answers to for date-time resolution.
    ///
    /// Read from the pack, not matched against an entity id. The compiler used
    /// to emit a bare `runtime.builtin` for every dynamic entity, which said the
    /// runtime resolves it but not what to resolve it as — leaving the id as the
    /// only discriminator, and making a rename a silent breakage (VIK-019). It
    /// now qualifies the source, so dispatch is on what the pack SAYS.
    static let dateTimeSource = "runtime.builtin.datetime"

    /// Fallback for packs built before that fix, which qualify nothing. Matching
    /// on the id is wrong in principle and correct in practice for exactly these
    /// packs, so it is scoped to them rather than being the general rule.
    static let legacyDateTimeEntityIDs: Set<String> = ["sys.date_time", "sys.date-time"]
    static let unqualifiedBuiltinSource = "runtime.builtin"

    private static let log = Logger(subsystem: "com.voiceintentkit", category: "PackSlotResolver")

    /// - Parameters:
    ///   - stopwords: fuzzy-matching stopwords; see `PackEntityExtractor`.
    ///   - openEntities: EXTRA open entities, on top of whatever the pack
    ///     declares. Normally empty — the pack is the source of truth now that
    ///     the compiler emits `open`. Kept only so a host can work around a pack
    ///     that is missing the flag without waiting for a rebuild.
    init(pack: ResolvedPack,
                timeZone: TimeZone = .current,
                stopwords: Set<String>? = nil,
                openEntities: Set<String> = []) {
        self.entities = PackEntityExtractor(pack: pack,
                                            stopwords: stopwords,
                                            openEntities: pack.openEntities.union(openEntities))
        self.datetime = PackDateTimeParser(grammar: pack.lexicon.datetime, timeZone: timeZone)
        self.timeZone = timeZone

        // Dispatch on the pack's declared source. Fall back to id matching only
        // for a pack that declares nothing usable, and say so — a runtime
        // guessing from an id is exactly what VIK-019 asked the format to stop
        // requiring.
        var dateTime: Set<String> = []
        var unqualified: Set<String> = []
        for id in pack.dynamicEntities {
            let source = pack.builtinSources[id]
            if source == Self.dateTimeSource {
                dateTime.insert(id)
            } else if source == nil || source == Self.unqualifiedBuiltinSource {
                unqualified.insert(id)
                if Self.legacyDateTimeEntityIDs.contains(id) { dateTime.insert(id) }
            }
        }
        self.dateTimeEntities = dateTime

        // A slot pointing at a builtin we cannot resolve never fills. The user
        // is re-prompted three times and then dropped to fallback, and nothing
        // in the logs says the entity was the reason — so say it here, once, at
        // load, while there is still a stack to attribute it to.
        var unsupported: Set<String> = []
        for (_, workflow) in pack.intents {
            for slot in workflow.slots
            where pack.dynamicEntities.contains(slot.entity)
                && !dateTimeEntities.contains(slot.entity) {
                unsupported.insert(slot.entity)
            }
        }
        if !unsupported.isEmpty {
            // Flattened before the log call — see the same note in
            // `PackContentGaps.logIfPresent` (VIK-005).
            let names: String = unsupported.sorted().joined(separator: ", ")
            Self.log.error("""
                Pack \(pack.manifest.bundleID, privacy: .public) has slots on builtin \
                entities this runtime does not implement: \(names, privacy: .public). \
                Those slots cannot fill.
                """)
        }
        if !unqualified.isEmpty {
            let names: String = unqualified.sorted().joined(separator: ", ")
            Self.log.notice("""
                Pack \(pack.manifest.bundleID, privacy: .public) declares an unqualified \
                `runtime.builtin` for \(names, privacy: .public); dispatching on entity id \
                instead. Rebuild against a compiler carrying the VIK-019 fix.
                """)
        }
        if pack.openEntities.isEmpty && !pack.entities.isEmpty {
            Self.log.notice("""
                Pack \(pack.manifest.bundleID, privacy: .public) declares no `open` entity. \
                If it has a free-text slot, that slot cannot fill — the pack predates the \
                VIK-017 fix.
                """)
        }
    }

    // MARK: SlotResolving

    func isDateTime(_ entity: String) -> Bool { dateTimeEntities.contains(entity) }

    func isOpen(_ entity: String) -> Bool { entities.isOpen(entity) }

    func extract(_ entity: String, from text: String, isDirectAnswer: Bool) -> String? {
        entities.extract(entity, from: text, allowFuzzy: isDirectAnswer)?.value
    }

    func dateTime(in text: String, now: Date) -> SlotDateTime? {
        guard let match = datetime.parse(text, now: now) else { return nil }
        return SlotDateTime(iso: localISO(match.date),
                            timeExplicit: match.timeExplicit,
                            explicitDay: match.dayExplicit)
    }

    func strippingDateTime(_ text: String) -> String {
        datetime.strippingDateTime(text)
    }

    // MARK: Formatting

    /// Local wall-clock ISO to the minute.
    ///
    /// Built from `DateComponents` rather than a `DateFormatter` because a
    /// `DateFormatter` is not `Sendable`, and holding one would force this type
    /// to be a reference type or to allocate a formatter per utterance. The
    /// output is identical to `DateFormatter` with `en_US_POSIX` and
    /// `"yyyy-MM-dd'T'HH:mm"`, which is what the engine parses back.
    private func localISO(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d",
                      c.year ?? 0, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0)
    }
}
