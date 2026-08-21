// PackTestSupport.swift
// VoiceIntentKitTests
//
// Shared fixtures: locating the vendored pack, loading it once, and decoding
// the reference expectations captured from the Python engine.

import Foundation
import XCTest
@testable import VoiceIntentKit

enum PackTestSupport {

    /// The pack these tests run against — the SAME bytes the app ships.
    ///
    /// Read from `Sources/VoiceIntentSeedPackEN/`, the seed target's resource
    /// directory, rather than a separate fixture copy. Two copies would drift,
    /// and the failure mode is the worst kind: a green suite proving something
    /// about a pack no device ever sees.
    ///
    /// Reached by walking `#filePath` rather than through the seed target's
    /// `Bundle.module`, so the test target does not have to depend on the seed
    /// library — the dependency would exist only to find a folder, and it would
    /// let a test accidentally exercise the seed's bundle layout instead of the
    /// loader's.
    static func packRoot() throws -> URL {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoiceIntentKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // VoiceIntentKit
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceIntentSeedPackEN")
            // The packs live one level down, under `packs/`, because the seed
            // target declares `.copy("packs")` — a single resource whose
            // directory tree is preserved verbatim. Pointing at the target root
            // instead found `SeedPack.swift` and `packs`, neither of which has
            // the `pack-` prefix, so every test that calls this XCTSkipped and
            // the suite went green without loading a pack at all.
            .appendingPathComponent("packs")

        let contents = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        let packs = contents
            .filter { $0.lastPathComponent.hasPrefix("pack-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let newest = packs.last else {
            throw XCTSkip("No pack-* directory under Sources/VoiceIntentSeedPackEN/ — vendor one to run these tests")
        }
        return newest
    }

    /// Signature verification is skipped: these tests exercise parsing and
    /// resolution, and the dev public key is not vendored. `PackLoadingTests`
    /// covers the trust chain separately.
    static let trust = PackTrustPolicy.unverifiedForTesting

    static func loadPack(variant: ClassifierVariant = .full) throws -> ResolvedPack {
        try BundleDataLoader.load(packAt: packRoot(),
                                  variant: variant,
                                  trust: trust,
                                  policy: .default)
    }

    // MARK: - Taxonomy, resolved FROM the pack

    /// The pack's intent whose required slots are exactly the ones named.
    ///
    /// DERIVED, not written down. The id was `reminders.task.create`; the compiler's
    /// `Cmd.*` rename made it `reminders.add`, and because these tests had been
    /// silently skipping, the change surfaced as eight assertions reading
    /// "reminders.add is not equal to reminders.task.create" — the symptom, not the
    /// cause. Selecting on the SHAPE a test needs survives the next rename too.
    ///
    /// Matching on "has any required slot" is not enough and was a bug in the first
    /// version of this helper: `pack-en` has two such intents — `Cmd.MemoryChange`
    /// (`memory_name`) and `reminders.add` (`name`, `date_time`) — and taking the
    /// first sorted one silently returned `Cmd.MemoryChange`, because uppercase sorts
    /// before lowercase. Every caller then tested the wrong flow, confidently.
    ///
    /// Ambiguity is therefore an ERROR, never a pick. A helper that guesses is how
    /// the thing it was written to prevent happens again.
    static func intent(requiringSlots required: Set<String>,
                       in pack: ResolvedPack) throws -> String {
        let matches = pack.intents.filter { _, workflow in
            let names = Set(workflow.slots.filter(\.required).map(\.name))
            return required.isSubset(of: names)
        }.keys.sorted()

        if matches.count > 1 {
            throw AmbiguousIntent(required: required, matches: matches)
        }
        guard let only = matches.first else {
            throw XCTSkip("""
                No intent in this pack requires \(required.sorted()) — there is no such \
                flow to exercise. Not a failure: a pack shape these tests cannot describe.
                """)
        }
        return only
    }

    struct AmbiguousIntent: Error, CustomStringConvertible {
        let required: Set<String>
        let matches: [String]
        var description: String {
            """
            \(matches) all require \(required.sorted()); the test cannot know which flow \
            it means. Narrow the slot set rather than letting the helper choose.
            """
        }
    }

    /// Fails with a message about the TAXONOMY when a hardcoded label is no longer
    /// one the model emits, instead of letting four unrelated assertions mismatch.
    static func assertLabelsExist(_ labels: [String], in pack: ResolvedPack,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let known = Set(pack.classifier.labels)
        let missing = labels.filter { !known.contains($0) }
        XCTAssertTrue(missing.isEmpty, """
            \(missing) are not labels this pack emits — the intent taxonomy moved. \
            The pack trains: \(known.sorted().prefix(8).joined(separator: ", "))…
            """, file: file, line: line)
    }

    // MARK: - Reference expectations


    struct Reference: Decodable {
        let now: String
        let datetime: [DateTimeCase]
        let entities: [EntityCase]

        struct DateTimeCase: Decodable {
            let text: String
            /// nil means the reference resolved nothing.
            let iso: String?
            let timeExplicit: Bool
            let dayExplicit: Bool
        }

        struct EntityCase: Decodable {
            let entity: String
            let text: String
            let value: String?
            let span: String?
            let confidence: Double
        }
    }

    static func reference() throws -> Reference {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/reference_expectations.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Reference.self, from: data)
    }

    /// The clock every expectation was captured at. Parsing is relative to
    /// "now", so a moving clock would make these tests meaningless.
    static func referenceNow(_ reference: Reference) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: reference.now) else {
            throw XCTSkip("Unparsable reference clock: \(reference.now)")
        }
        return date
    }

    /// Parse an ISO instant from the reference.
    ///
    /// The fixture generator now emits full second precision. It previously used
    /// the engine's own `timespec="minutes"` form (`2026-08-04T09:00+00:00`),
    /// which `ISO8601DateFormatter` CANNOT parse — the type has no
    /// minute-precision option, so every fixture returned nil and 29 cases
    /// reported as "unparsable fixture". That read as parser divergence and was
    /// nothing of the sort. Fixed at the source rather than by guessing at a
    /// format string here.
    ///
    /// The fractional-seconds attempt stays because it costs nothing and the
    /// generator is free to change.
    static func instant(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso) { return date }

        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        return internet.date(from: iso)
    }
}
