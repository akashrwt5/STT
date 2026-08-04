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
