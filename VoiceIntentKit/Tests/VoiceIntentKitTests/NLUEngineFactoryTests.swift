// NLUEngineFactoryTests.swift
// STTTests
//
// Unit tests for the NLU variant → factory → engine wiring.
//
// PLATFORM NOTE: the engine-construction tests build a real classifier, which
// loads CoreML resources from the host app bundle (Bundle.main == STT.app, since
// STTTests is hosted by the STT app). They therefore run on macOS + Xcode only.
// The variant-metadata and factory-type-mapping tests are pure and run anywhere
// the test bundle loads.

import XCTest
@testable import VoiceIntentKit

final class NLUEngineFactoryTests: XCTestCase {

    // MARK: - Variant metadata

    func testVariantRawValuesArePersistable() {
        // @AppStorage relies on the String RawValue round-tripping exactly.
        XCTAssertEqual(NLUVariant.english.rawValue, "english")
        XCTAssertEqual(NLUVariant.multilingual.rawValue, "multilingual")
        XCTAssertEqual(NLUVariant(rawValue: "english"), .english)
        XCTAssertEqual(NLUVariant(rawValue: "multilingual"), .multilingual)
        XCTAssertNil(NLUVariant(rawValue: "klingon"))
    }

    func testVariantIdentityAndDisplayName() {
        XCTAssertEqual(NLUVariant.english.id, "english")
        XCTAssertEqual(NLUVariant.multilingual.id, "multilingual")
        XCTAssertEqual(NLUVariant.english.displayName, "English")
        XCTAssertEqual(NLUVariant.multilingual.displayName, "Multilingual")
    }

    func testAllCasesCoverEveryVariant() {
        XCTAssertEqual(Set(NLUVariant.allCases), [.english, .multilingual])
    }

    // MARK: - Factory type mapping
    //
    // Pure: asserts make(for:) returns the correct concrete factory without
    // constructing any classifier (no resource load).

    func testProviderMapsEnglishToEnglishFactory() {
        XCTAssertTrue(NLUEngineFactoryProvider.make(for: .english) is EnglishNLUEngineFactory)
    }

    func testProviderMapsMultilingualToMultilingualFactory() {
        XCTAssertTrue(NLUEngineFactoryProvider.make(for: .multilingual) is MultilingualNLUEngineFactory)
    }

    // MARK: - Engine construction (macOS host only)

    /// The English factory builds a usable engine that starts in a non-collecting
    /// state. Exercises the full factory → classifier → engine wiring.
    func testEnglishFactoryBuildsIdleEngine() async {
        let engine = NLUEngineFactoryProvider.make(for: .english).makeEngine()
        let collecting = await engine.isCollecting
        XCTAssertFalse(collecting, "a freshly built engine is not mid-conversation")
        await engine.reset()  // must be safe to call on an idle engine
    }

    /// The Multilingual factory builds a usable engine. Its classifier degrades to
    /// JSON weights if the .mlpackage is absent, so construction must not crash as
    /// long as the weights JSON is bundled (it is, in the app target).
    func testMultilingualFactoryBuildsIdleEngine() async {
        let engine = NLUEngineFactoryProvider.make(for: .multilingual).makeEngine()
        let collecting = await engine.isCollecting
        XCTAssertFalse(collecting, "a freshly built engine is not mid-conversation")
        await engine.reset()
    }
}
