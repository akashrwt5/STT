// LocalizationLoaderTests.swift
// STTTests
//
// Phase 0 (P0-7) coverage for the multilingual NLU localization layer:
//   • merge loader keeps canonical structure, swaps only strings
//   • yes/no (affirmative/negative) is localized per language
//   • graceful degradation to English on a missing overlay (no crash)
//   • lexicon loads for a real language and is nil for an unknown one
//   • localized enum-synonym extraction (fr "voiture" → "Car") with the
//     English path byte-identical
//   • the factory builds a language-specific engine
//
// PLATFORM NOTE: these tests read localization JSON from `Bundle.main`
// (the STT app bundle, since STTTests is app-hosted) exactly as the loader
// does at runtime. Like the engine-construction tests in
// NLUEngineFactoryTests, they run on the macOS + Xcode host. They require the
// nine Localization/*.json resources to be members of the app target.

import XCTest
@testable import STT

final class LocalizationLoaderTests: XCTestCase {

    // MARK: - Merge: structure preserved, strings localized

    /// schema(language:"fr") must carry French prompts while keeping the
    /// canonical structural fields (entity / required / action) byte-identical
    /// to the English schema. The overlay is a strings patch, never a schema.
    func testMergeKeepsStructureSwapsStrings_fr() {
        let en = NLUSchema.loadFromBundle()
        let fr = LocalizationLoader.schema(language: "fr")

        guard let enIntent = en.intents["Cmd.MemoryChange"],
              let frIntent = fr.intents["Cmd.MemoryChange"],
              let enSlot = enIntent.slots.first(where: { $0.name == "MemoryName" }),
              let frSlot = frIntent.slots.first(where: { $0.name == "MemoryName" })
        else {
            return XCTFail("Cmd.MemoryChange / MemoryName missing from a schema")
        }

        // Structure: identical across languages.
        XCTAssertEqual(frIntent.action, enIntent.action, "action must not be localized")
        XCTAssertEqual(frSlot.entity, enSlot.entity, "slot entity must not be localized")
        XCTAssertEqual(frSlot.required, enSlot.required, "slot required must not be localized")

        // Strings: localized (French prompt differs from English).
        XCTAssertNotEqual(frSlot.prompt, enSlot.prompt, "French slot prompt should differ from English")
        XCTAssertFalse(frSlot.prompt.isEmpty, "French prompt should be present after merge")

        // affirmative is a localized strings field too.
        XCTAssertTrue(fr.affirmative.contains("oui"), "French affirmative should include 'oui'")
    }

    // MARK: - Yes/No localized per language

    func testYesNoLocalized_de() {
        let de = LocalizationLoader.schema(language: "de")
        XCTAssertTrue(de.affirmative.contains("ja"),   "German affirmative should include 'ja'")
        XCTAssertTrue(de.negative.contains("nein"),    "German negative should include 'nein'")
    }

    func testYesNoLocalized_da() {
        let da = LocalizationLoader.schema(language: "da")
        XCTAssertTrue(da.negative.contains("nej"),     "Danish negative should include 'nej'")
        XCTAssertTrue(da.affirmative.contains("jo"),   "Danish affirmative should include 'jo'")
    }

    // MARK: - Graceful degradation

    /// A missing overlay (unknown language) must fall back to the English
    /// canonical schema without crashing — never fatalError.
    func testMissingOverlayDegradesToEnglish() {
        let en = NLUSchema.loadFromBundle()
        let fallback = LocalizationLoader.schema(language: "xx")

        XCTAssertEqual(fallback.affirmative, en.affirmative,
                       "unknown language should yield the English affirmative list")
        XCTAssertEqual(fallback.negative, en.negative,
                       "unknown language should yield the English negative list")

        let enPrompt = en.intents["Cmd.MemoryChange"]?.slots
            .first(where: { $0.name == "MemoryName" })?.prompt
        let fbPrompt = fallback.intents["Cmd.MemoryChange"]?.slots
            .first(where: { $0.name == "MemoryName" })?.prompt
        XCTAssertEqual(fbPrompt, enPrompt, "unknown language should yield English prompts")
    }

    // MARK: - Lexicon loading

    func testLexiconLoadsForFrenchAndNilForUnknown() {
        guard let fr = LocalizationLoader.lexicon(language: "fr") else {
            return XCTFail("French lexicon should decode from nlu_lexicon.fr.json")
        }
        XCTAssertFalse(fr.uncertain.isEmpty,      "French uncertain list should be populated")
        XCTAssertFalse(fr.noIdioms.isEmpty,       "French no_idioms list should be populated")
        XCTAssertFalse(fr.carrierPhrases.isEmpty, "French carrier_phrases list should be populated")

        XCTAssertNil(LocalizationLoader.lexicon(language: "xx"),
                     "unknown language lexicon should be nil so callers use English defaults")
    }

    // MARK: - Localized enum-synonym extraction (English unchanged)

    /// The French entities file maps "voiture" → "Car". Built against the
    /// localized entities URL, the extractor resolves the French synonym.
    /// The default (English) extractor still resolves the English synonym —
    /// the English path is byte-identical to today.
    func testFrenchEnumSynonymExtraction() {
        guard let frURL = LocalizationLoader.entitiesURL(language: "fr") else {
            return XCTFail("French entities URL should resolve")
        }
        let fr = EntityExtractor(entitiesURL: frURL)
        XCTAssertEqual(fr.extract("memory", from: "change la mémoire voiture"), "Car",
                       "French 'voiture' should map to the 'Car' memory")

        let en = EntityExtractor()  // default English bundle
        XCTAssertEqual(en.extract("memory", from: "change to the car memory"), "Car",
                       "English path unchanged: 'car' still maps to 'Car'")
    }

    // MARK: - Factory builds a language-specific engine

    func testMultilingualFactoryBuildsFrenchEngine() async {
        let engine = NLUEngineFactoryProvider.make(for: .multilingual).makeEngine(language: "fr")
        let collecting = await engine.isCollecting
        XCTAssertFalse(collecting, "a freshly built French engine is not mid-conversation")
        await engine.reset()
    }
}
