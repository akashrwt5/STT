// NLUEngineFactoryTests.swift
// VoiceIntentKitTests
//
// Verifies the language-keyed `NLUEngineFactoryProvider` plus the
// `LanguagePackRegistry` that drives it. Adding a language ⇒ dropping a
// manifest + resources; these tests fail loudly if that story breaks.
//
// PLATFORM NOTE: engine-construction tests load real CoreML resources from
// the package bundle. They therefore run on macOS + Xcode only.

import XCTest
@testable import VoiceIntentKit

final class NLUEngineFactoryTests: XCTestCase {

    // MARK: - Registry

    func testRegistryDiscoversBundledPacks() {
        let codes = Set(LanguagePackRegistry.availableLanguages().map { $0.language })
        XCTAssertTrue(codes.contains("en"), "English pack must ship")
        XCTAssertTrue(codes.contains("fr"), "French pack must ship")
        XCTAssertTrue(codes.contains("de"), "German pack must ship")
        XCTAssertTrue(codes.contains("da"), "Danish pack must ship")
    }

    func testRegistryPackLookupResolvesLanguageMetadata() {
        let fr = LanguagePackRegistry.pack(for: "fr")
        XCTAssertNotNil(fr)
        XCTAssertEqual(fr?.locale, "fr-FR")
        XCTAssertEqual(fr?.displayName, "Français")
        XCTAssertEqual(fr?.classifier.kind, .shared)
        XCTAssertEqual(fr?.classifier.model, "IntentClassifier_multilingual")
        XCTAssertEqual(fr?.classifier.confThreshold, 0.60, "French uses the tuned multilingual threshold")
        XCTAssertNotNil(fr?.schemaOverlay, "French rides on the multilingual model with an overlay")
    }

    func testRegistryPackForEnglishHasDedicatedClassifier() {
        let en = LanguagePackRegistry.pack(for: "en")
        XCTAssertEqual(en?.classifier.kind, .dedicated)
        XCTAssertEqual(en?.classifier.model, "IntentClassifier")
        XCTAssertEqual(en?.classifier.confThreshold, 0.70, "English keeps the pre-refactor 0.70 gate")
        XCTAssertNil(en?.schemaOverlay, "English pack owns the canonical schema, no overlay")
    }

    func testRegistryUnknownCodeReturnsNil() {
        XCTAssertNil(LanguagePackRegistry.pack(for: "xx"))
    }

    // MARK: - Engine construction (macOS host only)

    /// English builds a usable engine that starts in a non-collecting state.
    func testMakeEngineForEnglishReturnsIdleEngine() async {
        let engine = NLUEngineFactoryProvider.makeEngine(language: "en")
        let collecting = await engine.isCollecting
        XCTAssertFalse(collecting, "a freshly built engine is not mid-conversation")
        await engine.reset()
    }

    /// A multilingual-riding pack (French) builds a usable engine. Its
    /// classifier degrades to JSON weights if the .mlpackage is absent, so
    /// construction must not crash as long as the weights JSON is bundled.
    func testMakeEngineForFrenchReturnsIdleEngine() async {
        let engine = NLUEngineFactoryProvider.makeEngine(language: "fr")
        let collecting = await engine.isCollecting
        XCTAssertFalse(collecting)
        await engine.reset()
    }

    /// Unknown language falls back to an English-defaults engine rather than
    /// crashing. The service contract: `makeEngine(language:)` always returns
    /// a working engine.
    func testMakeEngineForUnknownLanguageFallsBackToEnglish() async {
        let engine = NLUEngineFactoryProvider.makeEngine(language: "xx")
        let collecting = await engine.isCollecting
        XCTAssertFalse(collecting)
        await engine.reset()
    }
}
