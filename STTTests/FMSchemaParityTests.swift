// FMSchemaParityTests.swift
// STTTests
//
// Drift guard for the Foundation Models sample (docs/FM_SAMPLE_PLAN.md §4):
// FMIntent's label set must exactly match the production classifier's label
// inventory in Resources/intent_classifier_weights.json. If an intent is
// added, removed, or renamed in the production model, these tests fail until
// the FM enum follows — the FM sample can never silently classify against a
// stale vocabulary.

import XCTest
@testable import STT

#if canImport(FoundationModels)

@available(iOS 26.0, *)
final class FMSchemaParityTests: XCTestCase {

    /// Labels the production classifier ships with (source of truth).
    private func bundledLabels() throws -> [String] {
        let bundle = Bundle(for: type(of: self))
        // Weights JSON lives in the app bundle, not the test bundle.
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "intent_classifier_weights", withExtension: "json")
                ?? bundle.url(forResource: "intent_classifier_weights", withExtension: "json"),
            "intent_classifier_weights.json not found in app or test bundle"
        )
        let data = try Data(contentsOf: url)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(obj["labels"] as? [String], "weights JSON has no 'labels' array")
    }

    func testEveryProductionLabelHasAnFMCase() throws {
        let production = Set(try bundledLabels())
        let fm = Set(FMIntent.allCases.map(\.label))
        let missing = production.subtracting(fm).sorted()
        XCTAssertTrue(missing.isEmpty,
                      "Production labels missing from FMIntent: \(missing)")
    }

    func testNoFMCaseInventsALabel() throws {
        let production = Set(try bundledLabels())
        let fm = Set(FMIntent.allCases.map(\.label))
        let invented = fm.subtracting(production).sorted()
        XCTAssertTrue(invented.isEmpty,
                      "FMIntent labels that don't exist in production: \(invented)")
    }

    func testLabelMappingIsUnique() {
        let labels = FMIntent.allCases.map(\.label)
        XCTAssertEqual(labels.count, Set(labels).count,
                       "Two FMIntent cases map to the same production label")
    }

    func testOutOfScopeMapsToDefaultFallbackIntent() {
        XCTAssertEqual(FMIntent.outOfScope.label, "Default Fallback Intent")
    }

    func testReverseLookupRoundTrips() {
        for intent in FMIntent.allCases {
            XCTAssertEqual(FMIntent.from(label: intent.label), intent)
        }
    }

    func testInstructionCatalogWithinTokenBudget() {
        XCTAssertLessThan(FMPromptBuilder.estimatedTokenCount,
                          FMPromptBuilder.instructionTokenBudget,
                          "Instruction catalog outgrew its context budget — trim descriptions")
    }

    /// The bundled holdout must parse and cover the expected shape (341 rows,
    /// every expected label a real production label).
    func testBundledHoldoutParsesAndLabelsAreValid() throws {
        let production = Set(try bundledLabels())
        let rows = FMBenchmark.loadHoldout()
        XCTAssertGreaterThan(rows.count, 300, "Holdout unexpectedly small — CSV parse regression?")
        let unknown = Set(rows.map(\.expected)).subtracting(production).sorted()
        XCTAssertTrue(unknown.isEmpty,
                      "Holdout expects labels the production model doesn't have: \(unknown)")
    }
}

#endif
