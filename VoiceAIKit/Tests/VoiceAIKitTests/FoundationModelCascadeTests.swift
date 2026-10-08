// FoundationModelCascadeTests.swift
// VoiceAIKitTests
//
// The language model stage, tested without the language model: a stub stands
// in for `FoundationModelIntentClassifier`, so these run on any simulator and
// say nothing about the real model's accuracy. That is measured separately,
// on the holdout set, on a device that has the model.

import XCTest
@testable import VoiceAIKit

// MARK: - Stubs

/// A pack classifier that returns one scripted answer.
private actor StubPackClassifier: IntentClassifying {
    private let label: String
    private let confidence: Double
    private let arbitration: ClassificationResult.Arbitration?
    private let oov: Double
    private(set) var classifyCalls = 0

    init(label: String, confidence: Double,
         arbitration: ClassificationResult.Arbitration? = nil, oov: Double = 0) {
        self.label = label
        self.confidence = confidence
        self.arbitration = arbitration
        self.oov = oov
    }

    func classifyAsync(_ text: String) async -> ClassificationResult {
        classifyCalls += 1
        return ClassificationResult(
            label: label, confidence: confidence, semanticRescue: false,
            breakdown: ClassificationBreakdown(
                winningStage: 2,
                stage2: .init(stage: 2, intent: label, confidence: confidence),
                stage3: nil),
            arbitration: arbitration)
    }

    func calibratedConfidence(for intent: String) async -> Double? { 0.42 }
    func oovRatio(_ text: String) async -> Double { oov }
    func warmUp() async {}
    func loadStage3() async {}
    func releaseStage3() async {}
}

/// A generative model that returns one scripted verdict, or nil to act unavailable.
private actor StubGenerative: GenerativeIntentClassifying {
    private let verdict: GenerativeVerdict?
    private(set) var classifyCalls = 0
    private(set) var prewarmCalls = 0

    init(intent: String?, confidence: Double = 0.9) {
        verdict = intent.map { GenerativeVerdict(intent: $0, confidence: confidence, latency: .zero) }
    }

    func classify(_ text: String) async -> GenerativeVerdict? {
        classifyCalls += 1
        return verdict
    }

    func prewarm() async { prewarmCalls += 1 }
}

// MARK: - Cascade

final class FoundationModelCascadeTests: XCTestCase {

    private let fallback = "Default Fallback Intent"
    private let bars = FoundationModelCascade.Bars(confidence: 0.70, agreement: 0.50,
                                                   oovReject: 0.25, oovBypass: 0.97)

    private func cascade(_ base: StubPackClassifier, _ generative: StubGenerative,
                         mode: IntentClassifierMode) -> FoundationModelCascade {
        FoundationModelCascade(base: base, generative: generative, mode: mode,
                               outOfScopeIntent: fallback, bars: bars)
    }

    // MARK: Pack with FM fallback

    func testFallbackModeKeepsAConfidentPackAnswerAndDoesNotAskTheModel() async {
        let base = StubPackClassifier(label: "Cmd.VolumeIncrease", confidence: 0.95)
        let model = StubGenerative(intent: "Help_Volume")
        let result = await cascade(base, model, mode: .packWithFoundationModelFallback).classifyAsync("louder")

        XCTAssertEqual(result.label, "Cmd.VolumeIncrease")
        XCTAssertNil(result.breakdown.stage3)
        let calls = await model.classifyCalls
        XCTAssertEqual(calls, 0)
    }

    func testFallbackModeAsksTheModelWhenThePackFallsBack() async {
        let base = StubPackClassifier(label: fallback, confidence: 0.40)
        let model = StubGenerative(intent: "Help_FindMyHearingAids", confidence: 0.85)
        let result = await cascade(base, model, mode: .packWithFoundationModelFallback).classifyAsync("where did my aids go")

        XCTAssertEqual(result.label, "Help_FindMyHearingAids")
        XCTAssertEqual(result.confidence, 0.85)
        XCTAssertEqual(result.breakdown.winningStage, FoundationModelCascade.generativeStage)
        XCTAssertEqual(result.breakdown.stage2?.intent, fallback, "the pack's reading is kept for comparison")
        XCTAssertEqual(result.breakdown.stage3?.intent, "Help_FindMyHearingAids")
    }

    func testFallbackModeAsksTheModelBelowTheConfidenceBar() async {
        let base = StubPackClassifier(label: "Cmd.VolumeIncrease", confidence: 0.65)
        let model = StubGenerative(intent: "Cmd.VolumeIncrease")
        _ = await cascade(base, model, mode: .packWithFoundationModelFallback).classifyAsync("x")
        let calls = await model.classifyCalls
        XCTAssertEqual(calls, 1)
    }

    func testFallbackModeUsesTheAgreementBarForACorroboratedTurn() async {
        // 0.65 is under the fire bar but over the agreement bar: the engine fires
        // this turn, so the model must not be asked.
        let base = StubPackClassifier(label: "Cmd.VolumeIncrease", confidence: 0.65,
                                      arbitration: .corroborated)
        let model = StubGenerative(intent: "Help_Volume")
        let result = await cascade(base, model, mode: .packWithFoundationModelFallback).classifyAsync("x")
        XCTAssertEqual(result.label, "Cmd.VolumeIncrease")
        let calls = await model.classifyCalls
        XCTAssertEqual(calls, 0)
    }

    func testFallbackModeAsksTheModelWhenTheVocabularyGuardWouldBlock() async {
        // Confident, but a quarter of the words are unknown and the confidence is
        // under the bypass: the engine's OOV guard would refuse this turn.
        let base = StubPackClassifier(label: "Help_FindMyHearingAids", confidence: 0.77, oov: 0.25)
        let model = StubGenerative(intent: fallback, confidence: 0.9)
        let cascade = cascade(base, model, mode: .packWithFoundationModelFallback)
        let result = await cascade.classifyAsync("help me find a paper")

        XCTAssertEqual(result.label, fallback)
        let ratio = await cascade.oovRatio("help me find a paper")
        XCTAssertEqual(ratio, 0, "the vocabulary guard does not apply to the model's answer")
    }

    func testModelWithoutAnAnswerLeavesThePackAnswerUntouched() async {
        let base = StubPackClassifier(label: fallback, confidence: 0.30, oov: 0.5)
        let model = StubGenerative(intent: nil)
        let cascade = cascade(base, model, mode: .packWithFoundationModelFallback)
        let result = await cascade.classifyAsync("x")

        XCTAssertEqual(result.label, fallback)
        XCTAssertEqual(result.confidence, 0.30)
        XCTAssertNil(result.breakdown.stage3)
        let ratio = await cascade.oovRatio("x")
        XCTAssertEqual(ratio, 0.5, "the pack's own guard answers again")
        let calibrated = await cascade.calibratedConfidence(for: "anything")
        XCTAssertEqual(calibrated, 0.42)
    }

    // MARK: FM chooses (pack as backup)

    func testPrimaryModeUsesTheModelEvenWhenThePackIsConfident() async {
        let base = StubPackClassifier(label: "Cmd.VolumeIncrease", confidence: 0.99)
        let model = StubGenerative(intent: "Help_Volume", confidence: 0.80)
        let cascade = cascade(base, model, mode: .foundationModel)
        let result = await cascade.classifyAsync("how loud can it go")

        XCTAssertEqual(result.label, "Help_Volume")
        XCTAssertEqual(result.breakdown.stage2?.intent, "Cmd.VolumeIncrease")
        let calibrated = await cascade.calibratedConfidence(for: "Help_Volume")
        XCTAssertNil(calibrated, "the model has no distribution to re-read")
    }

    func testPrimaryModeFallsBackToThePackWhenTheModelIsUnavailable() async {
        let base = StubPackClassifier(label: "Cmd.VolumeIncrease", confidence: 0.99)
        let model = StubGenerative(intent: nil)
        let result = await cascade(base, model, mode: .foundationModel).classifyAsync("louder")
        XCTAssertEqual(result.label, "Cmd.VolumeIncrease")
        XCTAssertEqual(result.confidence, 0.99)
    }

    // MARK: Both modes

    func testAModelAnswerIsNeverASemanticRescue() async {
        // A semantic rescue skips the engine's confidence bar. A self-rated
        // confidence must not.
        for mode in [IntentClassifierMode.packWithFoundationModelFallback, .foundationModel] {
            let base = StubPackClassifier(label: fallback, confidence: 0.1)
            let model = StubGenerative(intent: "Cmd.VolumeMute", confidence: 0.2)
            let result = await cascade(base, model, mode: mode).classifyAsync("x")
            XCTAssertFalse(result.semanticRescue, "\(mode)")
        }
    }

    func testTopicSwitchProbeNeverAsksTheModel() async {
        for mode in [IntentClassifierMode.packWithFoundationModelFallback, .foundationModel] {
            let base = StubPackClassifier(label: fallback, confidence: 0.1)
            let model = StubGenerative(intent: "Cmd.VolumeMute")
            let result = await cascade(base, model, mode: mode).classifyForTopicSwitch("outdoors")
            XCTAssertEqual(result.label, fallback, "\(mode)")
            let calls = await model.classifyCalls
            XCTAssertEqual(calls, 0, "\(mode)")
        }
    }

    func testPackOnlyNeverAsksTheModel() async {
        let base = StubPackClassifier(label: fallback, confidence: 0.1)
        let model = StubGenerative(intent: "Cmd.VolumeMute")
        let result = await cascade(base, model, mode: .packOnly).classifyAsync("x")
        XCTAssertEqual(result.label, fallback)
        let calls = await model.classifyCalls
        XCTAssertEqual(calls, 0)
    }

    func testWarmUpPrewarmsTheModel() async {
        let model = StubGenerative(intent: nil)
        await cascade(StubPackClassifier(label: fallback, confidence: 0), model, mode: .packWithFoundationModelFallback).warmUp()
        let calls = await model.prewarmCalls
        XCTAssertEqual(calls, 1)
    }
}

// MARK: - Engine, end to end

/// The real pack classifier and the real engine, with the model stubbed. Proves
/// the engine's bar applies to the model's answer.
final class FoundationModelEngineTests: XCTestCase {

    private var pack: ResolvedPack!
    private var schema: NLUSchema!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pack = try PackTestSupport.loadPack()
        schema = try PackEngineFactory.schema(from: pack)
    }

    private func makeEngine(modelSays intent: String, confidence: Double) throws -> NLUEngine {
        let base = try PackClassifierAdapter(pack: pack)
        let thresholds = pack.policies.thresholds
        let classifier = FoundationModelCascade(
            base: base,
            generative: StubGenerative(intent: intent, confidence: confidence),
            mode: .foundationModel,
            outOfScopeIntent: schema.fallbackIntent,
            bars: .init(confidence: thresholds.confidence, agreement: thresholds.agreement,
                        oovReject: thresholds.oovReject, oovBypass: thresholds.oovBypass))
        return NLUEngine(
            schema: schema,
            classifier: classifier,
            entities: PackSlotResolver(pack: pack),
            uncertain: [],
            noIdioms: [],
            carriers: pack.lexicon.carriers,
            interruptThreshold: thresholds.interrupt,
            maxSlotAttempts: pack.policies.limits.maxSlotAttempts,
            oovReject: thresholds.oovReject,
            oovBypass: thresholds.oovBypass,
            leadingConnectors: pack.lexicon.leadingConnectors,
            confirmationGates: PackEngineFactory.confirmationGates(from: pack),
            helpMarkerPattern: pack.guards.helpMarker?.markers,
            helpPairs: pack.guards.helpMarker?.pairs ?? [:])
    }

    func testAConfidentModelAnswerFires() async throws {
        // Help_Volume never confirms in pack-en, so a fired turn is a fulfil.
        let engine = try makeEngine(modelSays: "Help_Volume", confidence: 0.90)
        let response = await engine.handle("what are the loudness settings for")
        guard case .fulfill(let intent, _, _, _, let conf, let rescued, _, _) = response else {
            return XCTFail("expected a fulfilled turn, got \(response)")
        }
        XCTAssertEqual(intent, "Help_Volume")
        XCTAssertEqual(conf, 0.90)
        XCTAssertFalse(rescued)
    }

    func testAnUnsureModelAnswerStillFallsBack() async throws {
        let engine = try makeEngine(modelSays: "Help_Volume", confidence: 0.40)
        let response = await engine.handle("what are the loudness settings for")
        guard case .fallback = response else {
            return XCTFail("a self-rated 0.40 must not clear the 0.70 bar, got \(response)")
        }
    }
}

// MARK: - Settings and pack format

final class FoundationModelSettingsTests: XCTestCase {

    /// Whatever mode the seed pack chooses, a pack that turns the language model
    /// on must also carry its text, covering every label. Holds for any seed pack,
    /// so a pack swap does not need this test edited.
    func testTheSeedPackModeAndTextAgree() throws {
        let pack = try PackTestSupport.loadPack()
        let settings = FoundationModelSettings.resolve(pack: pack, override: nil)
        guard pack.classifierMode != .packOnly else {
            XCTAssertNil(settings)
            return
        }
        let resolved = try XCTUnwrap(settings)
        XCTAssertEqual(resolved.mode, pack.classifierMode)
        let llm = try XCTUnwrap(pack.llm, "the stage is on but llm/\(pack.language).json is missing")
        XCTAssertNotNil(llm.instructions)
        XCTAssertEqual(Set(llm.intentDescriptions.keys), Set(pack.classifier.labels))
        XCTAssertEqual(resolved.instructions, llm.instructions)
    }

    func testAPackOnlyOverrideBuildsNoLanguageModelStage() throws {
        let pack = try PackTestSupport.loadPack()
        XCTAssertNil(FoundationModelSettings.resolve(pack: pack,
                                                     override: FoundationModelOverride(mode: .packOnly)))
    }

    func testModeRawValuesAreThePackStrings() {
        XCTAssertEqual(IntentClassifierMode(rawValue: "pack_only"), .packOnly)
        XCTAssertEqual(IntentClassifierMode(rawValue: "pack_with_fm_fallback"), .packWithFoundationModelFallback)
        XCTAssertEqual(IntentClassifierMode(rawValue: "foundation_model"), .foundationModel)
    }

    func testAnOverrideReplacesThePackEntirely() throws {
        let pack = try PackTestSupport.loadPack()
        let override = FoundationModelOverride(mode: .packWithFoundationModelFallback, instructions: "I",
                                               intentDescriptions: ["Help_Volume": "D"],
                                               logsModelIO: true)
        let settings = try XCTUnwrap(FoundationModelSettings.resolve(pack: pack, override: override))
        XCTAssertEqual(settings.mode, .packWithFoundationModelFallback)
        XCTAssertEqual(settings.instructions, "I")
        XCTAssertEqual(settings.intentDescriptions, ["Help_Volume": "D"])
        XCTAssertTrue(settings.logsModelIO)
    }

    func testAModeOnlyOverrideUsesThePacksText() throws {
        let llm = PackLLM(instructions: "From the pack.", intentDescriptions: ["Help_Volume": "P"])
        let settings = try XCTUnwrap(FoundationModelSettings.resolve(
            packMode: .packOnly, packLLM: llm,
            override: FoundationModelOverride(mode: .packWithFoundationModelFallback)))
        XCTAssertEqual(settings.mode, .packWithFoundationModelFallback)
        XCTAssertEqual(settings.instructions, "From the pack.")
        XCTAssertEqual(settings.intentDescriptions, ["Help_Volume": "P"])
        XCTAssertFalse(settings.logsModelIO)
    }

    func testOverrideTextReplacesThePacksText() throws {
        let llm = PackLLM(instructions: "From the pack.", intentDescriptions: ["Help_Volume": "P"])
        let settings = try XCTUnwrap(FoundationModelSettings.resolve(
            packMode: .packOnly, packLLM: llm,
            override: FoundationModelOverride(mode: .foundationModel, instructions: "Mine",
                                              intentDescriptions: ["Help_Volume": "M"])))
        XCTAssertEqual(settings.instructions, "Mine")
        XCTAssertEqual(settings.intentDescriptions, ["Help_Volume": "M"])
    }

    func testThePacksModeAndTextWithoutAnOverride() throws {
        let llm = PackLLM(instructions: "From the pack.", intentDescriptions: [:])
        let settings = try XCTUnwrap(FoundationModelSettings.resolve(
            packMode: .packWithFoundationModelFallback, packLLM: llm, override: nil))
        XCTAssertEqual(settings.mode, .packWithFoundationModelFallback)
        XCTAssertEqual(settings.instructions, "From the pack.")
        XCTAssertNil(FoundationModelSettings.resolve(packMode: .packOnly, packLLM: llm, override: nil))
    }

    func testAPackOnlyOverrideWinsOverThePack() {
        XCTAssertNil(FoundationModelSettings.resolve(
            packMode: .foundationModel, packLLM: nil,
            override: FoundationModelOverride(mode: .packOnly)))
    }

    func testComposedInstructionsAddOnlyDescribedLabelsInLabelOrder() {
        let settings = FoundationModelSettings(mode: .foundationModel, instructions: "Pick one.",
                                               intentDescriptions: ["b": "Bee", "a": "Ay", "zz": "unused"])
        XCTAssertEqual(settings.composedInstructions(labels: ["a", "b", "c"]),
                       "Pick one.\na: Ay\nb: Bee")
    }

    func testNoLocaleLineForUSEnglish() {
        XCTAssertNil(FoundationModelSettings.localeLine(for: Locale(identifier: "en-US")))
        XCTAssertNil(FoundationModelSettings.localeLine(for: Locale(identifier: "en_US")))
    }

    func testLocaleLineUsesApplesExactPhrase() {
        XCTAssertEqual(FoundationModelSettings.localeLine(for: Locale(identifier: "de-DE")),
                       "The person's locale is de_DE.")
        XCTAssertEqual(FoundationModelSettings.localeLine(for: Locale(identifier: "en-GB")),
                       "The person's locale is en_GB.")
    }

    func testLocaleLineComesFirst() {
        let settings = FoundationModelSettings(mode: .foundationModel, instructions: "Pick one.",
                                               intentDescriptions: ["a": "Ay"])
        XCTAssertEqual(settings.composedInstructions(labels: ["a"], locale: Locale(identifier: "fr-FR")),
                       "The person's locale is fr_FR.\nPick one.\na: Ay")
        XCTAssertEqual(settings.composedInstructions(labels: ["a"], locale: Locale(identifier: "en-US")),
                       "Pick one.\na: Ay")
    }

    func testComposedInstructionsAreNilWhenThereIsNothingToSend() {
        let settings = FoundationModelSettings(mode: .foundationModel, instructions: nil, intentDescriptions: [:])
        XCTAssertNil(settings.composedInstructions(labels: ["a"]))
    }

    func testCascadeStageModeDecodes() throws {
        let json = #"{"stages":[{"id":"keyword","enabled":true},{"id":"foundation_model","enabled":true,"mode":"pack_with_fm_fallback"}]}"#
        let cascade = try JSONDecoder().decode(PackCascade.self, from: Data(json.utf8))
        XCTAssertTrue(cascade.isEnabled("foundation_model"))
        XCTAssertEqual(cascade.mode(of: "foundation_model"), "pack_with_fm_fallback")
        XCTAssertNil(cascade.mode(of: "keyword"))
    }

    func testOutOfScopeOverridesTheChosenLabel() {
        XCTAssertEqual(GenerativeVerdict.resolvedIntent(inScope: false, label: "Help_Accessories",
                                                        outOfScopeIntent: "Default Fallback Intent"),
                       "Default Fallback Intent")
        XCTAssertEqual(GenerativeVerdict.resolvedIntent(inScope: true, label: "Help_Accessories",
                                                        outOfScopeIntent: "Default Fallback Intent"),
                       "Help_Accessories")
    }

    // MARK: Backward compatibility

    func testAModeOfTheWrongTypeReadsAsAbsentAndKeepsTheCascade() throws {
        let json = #"{"stages":[{"id":"keyword","enabled":true},{"id":"foundation_model","enabled":true,"mode":3}]}"#
        let cascade = try JSONDecoder().decode(PackCascade.self, from: Data(json.utf8))
        XCTAssertTrue(cascade.isEnabled("keyword"))
        XCTAssertNil(cascade.mode(of: "foundation_model"))
    }

    func testACascadeWithoutTheStageDecodesAsBefore() throws {
        let json = #"{"stages":[{"id":"keyword","enabled":true},{"id":"semantic","enabled":false}]}"#
        let cascade = try JSONDecoder().decode(PackCascade.self, from: Data(json.utf8))
        XCTAssertFalse(cascade.isEnabled("foundation_model"))
        XCTAssertNil(cascade.mode(of: "foundation_model"))
    }

    func testLLMFileAbsentMalformedOrValid() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("llm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertNil(BundleDataLoader.loadLLM(root: root, language: "en"), "absent")

        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("en.json"))
        XCTAssertNil(BundleDataLoader.loadLLM(root: root, language: "en"), "malformed must not throw")

        try Data(#"{"instructions":"I","intent_descriptions":{"a":"b"}}"#.utf8)
            .write(to: dir.appendingPathComponent("en.json"))
        XCTAssertEqual(BundleDataLoader.loadLLM(root: root, language: "en"),
                       PackLLM(instructions: "I", intentDescriptions: ["a": "b"]))
    }

    func testAModelessOverrideLetsThePackDecideAndKeepsLogging() throws {
        let llm = PackLLM(instructions: "From the pack.", intentDescriptions: [:])
        let settings = try XCTUnwrap(FoundationModelSettings.resolve(
            packMode: .foundationModel, packLLM: llm,
            override: FoundationModelOverride(logsModelIO: true)))
        XCTAssertEqual(settings.mode, .foundationModel)
        XCTAssertEqual(settings.instructions, "From the pack.")
        XCTAssertTrue(settings.logsModelIO)
        XCTAssertNil(FoundationModelSettings.resolve(
            packMode: .packOnly, packLLM: llm, override: FoundationModelOverride(logsModelIO: true)),
            "a pack_only pack stays off when the override sets no mode")
    }

    /// `IntentClassifierMode` is this runtime's copy of the spec's closed list
    /// (`spec/bundle/3.0/cascade.schema.json`). The fixture is generated from the
    /// spec by the IntentClassifier repo, so a mode added or removed there fails
    /// here until the enum follows. Regenerate with:
    ///   PYTHONPATH=packages/buildtime python -m scripts.ci.emit_contract_fixtures \
    ///       --out <VoiceAIKit>/Tests/VoiceAIKitTests/Fixtures/foundation_model_modes.json
    func testIntentClassifierModeMatchesTheSpec() throws {
        struct Contract: Decodable {
            let modes: [String]
            let defaultMode: String
            enum CodingKeys: String, CodingKey {
                case modes = "foundation_model_modes"
                case defaultMode = "foundation_model_default_mode"
            }
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/foundation_model_modes.json")
        let contract = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))

        XCTAssertEqual(IntentClassifierMode.allCases.map(\.rawValue), contract.modes)
        // The mode a pack without the stage gets must be the spec's default.
        XCTAssertEqual(IntentClassifierMode(rawValue: contract.defaultMode), .packOnly)
    }

    func testAnUnknownModeIsNotAMode() {
        XCTAssertNil(IntentClassifierMode(rawValue: "always"))
    }

    func testLLMSectionDecodesWithAndWithoutOptionalKeys() throws {
        let full = #"{"instructions":"Pick one.","intent_descriptions":{"Help_Volume":"How to change volume"}}"#
        let llm = try JSONDecoder().decode(PackLLM.self, from: Data(full.utf8))
        XCTAssertEqual(llm.instructions, "Pick one.")
        XCTAssertEqual(llm.intentDescriptions["Help_Volume"], "How to change volume")

        let empty = try JSONDecoder().decode(PackLLM.self, from: Data("{}".utf8))
        XCTAssertNil(empty.instructions)
        XCTAssertTrue(empty.intentDescriptions.isEmpty)
    }
}
