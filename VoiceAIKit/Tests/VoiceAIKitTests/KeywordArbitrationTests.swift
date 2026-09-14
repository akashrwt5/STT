// KeywordArbitrationTests.swift
// VoiceAIKitTests
//
// VIK-055 — a keyword rule is a VOTE, not a BYPASS.
//
// `NLUEngine` used to carry a "Stage 0" that returned a matching rule's intent
// before the classifier ran. So "who is the prime minister of create reminder"
// matched `\b(set|create|add|make)\b.{0,20}\breminder\b` and opened the reminder
// flow, while Android and the Python reference put the same utterance on the
// fallback — their model answers `Default Fallback Intent`, the rule disagrees,
// and a contested turn is capped at 0.60 against a 0.70 bar.
//
// `classifier.py::classify` documents the same defect as already fixed there:
// "Previously the keyword stage short-circuited the model and returned a
// hardcoded constant, which put two incompatible scales in one field."
//
// TWO SUBJECTS, TWO KINDS OF TEST, and the split is the point:
//
//   * the ADAPTER decides the LABEL and the NUMBER. Tested against the REAL
//     `PackClassifierAdapter` over the vendored pack, because a stub classifier
//     IS the classifier and would bypass the code under test entirely.
//   * the ENGINE decides which BAR that number must clear. Tested with a stub
//     that states an arbitration verdict directly, because forcing a real model
//     into a chosen confidence band is not something a test can do honestly.

import XCTest
@testable import VoiceAIKit

/// States an arbitration verdict outright, so the engine's bar selection can be
/// exercised at a chosen confidence. The real adapter's job is tested separately.
private actor ArbitrationStubClassifier: IntentClassifying {

    private let label: String
    private let confidence: Double
    private let arbitration: ClassificationResult.Arbitration?

    init(label: String, confidence: Double,
         arbitration: ClassificationResult.Arbitration?) {
        self.label = label
        self.confidence = confidence
        self.arbitration = arbitration
    }

    func classifyAsync(_ text: String) async -> ClassificationResult {
        ClassificationResult(
            label: label, confidence: confidence, semanticRescue: false,
            breakdown: ClassificationBreakdown(
                winningStage: arbitration == nil ? 2 : 1,
                stage2: ClassificationBreakdown.StageResult(
                    stage: 2, intent: label, confidence: confidence),
                stage3: nil),
            arbitration: arbitration)
    }

    func warmUp() async {}
    func loadStage3() async {}
    func releaseStage3() async {}
    func oovRatio(_ text: String) async -> Double { 0 }
}

final class KeywordArbitrationTests: XCTestCase {

    private var pack: ResolvedPack!
    private var schema: NLUSchema!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pack = try PackTestSupport.loadPack()
        schema = try PackEngineFactory.schema(from: pack)
    }

    // MARK: - Helpers

    /// Does any rule claim `text`, honouring EVERY guard rather than the first?
    private func keywordIntent(for text: String) -> String? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        func hit(_ pattern: String) -> Bool {
            t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return pack.keywordRulesByTier.first { hit($0.pattern) && !$0.guards.contains(where: hit) }?.intent
    }

    private func fulfilled(_ response: NLUResponse) -> (intent: String, confidence: Double)? {
        guard case .fulfill(let intent, _, _, _, let conf, _, _) = response else { return nil }
        return (intent, conf)
    }

    /// An intent this pack can fire in one turn: no slots, and never confirmed.
    /// Derived, never named — the taxonomy has moved twice already.
    private func slotlessUngatedIntent() throws -> String {
        try XCTUnwrap(
            schema.intents.keys
                .filter { schema.intents[$0]?.slots.isEmpty == true }
                .filter { PackEngineFactory.confirmationGates(from: pack)[$0] == .never }
                .sorted().first,
            "no intent in this pack is both slotless and ungated")
    }

    /// Built exactly as `PackEngineFactory` builds one, with the stub swapped in.
    private func engine(label: String, confidence: Double,
                        arbitration: ClassificationResult.Arbitration?,
                        agreement: Double?) -> NLUEngine {
        NLUEngine(
            schema: schema,
            classifier: ArbitrationStubClassifier(label: label, confidence: confidence,
                                                  arbitration: arbitration),
            entities: PackSlotResolver(pack: pack),
            uncertain: [],
            noIdioms: [],
            carriers: pack.lexicon.carriers,
            interruptThreshold: pack.policies.thresholds.interrupt,
            maxSlotAttempts: pack.policies.limits.maxSlotAttempts,
            // The OOV guard is a separate turn-killer; this suite is about the
            // fire bar alone, and leaving it on would make a failure ambiguous.
            oovReject: nil,
            oovBypass: nil,
            agreementThreshold: agreement,
            leadingConnectors: pack.lexicon.leadingConnectors,
            confirmationGates: PackEngineFactory.confirmationGates(from: pack))
    }

    // MARK: - The pack's own data

    /// The premise every test below rests on. `agreement` is what drops the bar
    /// for a corroborated turn; without it this suite proves only half of itself.
    func testThePackDeclaresAnAgreementThresholdBelowTheFireThreshold() throws {
        let agreement = try XCTUnwrap(pack.policies.thresholds.agreement,
                                      "policies.json carries no thresholds.agreement")
        XCTAssertLessThan(agreement, pack.policies.thresholds.confidence, """
            an agreement bar at or above the fire threshold cannot admit anything \
            the fire threshold would not already admit, so corroboration would be \
            a no-op
            """)
    }

    /// The contested confidence must sit BELOW the fire threshold, or a rule the
    /// model contradicts could fire on its own — which is the whole defect.
    func testTheContestedConfidenceCannotClearTheFireThreshold() {
        XCTAssertLessThan(PackClassifierAdapter.contestedConfidence,
                          pack.policies.thresholds.confidence)
    }

    /// VIK-058. The engine reads every guard now; this records the assumption
    /// that made that safe to change without a measurement.
    func testNoKeywordRuleShipsMoreThanOneGuard() {
        for rule in pack.keywordRules where rule.guards.count > 1 {
            XCTFail("""
                \(rule.intent) ships \(rule.guards.count) guards. That is legal and now \
                honoured, but the change was landed on the evidence that no rule did — \
                re-measure rather than assume.
                """)
        }
    }

    /// `NSRegularExpression` is not Python's `re`. A pattern that fails here
    /// drops its rule silently, so the failure belongs in a test.
    func testEveryKeywordPatternCompilesOnThisPlatform() {
        for rule in pack.keywordRules {
            XCTAssertNoThrow(try NSRegularExpression(pattern: rule.pattern,
                                                     options: [.caseInsensitive]),
                             "the pattern for \(rule.intent) does not compile here")
            for veto in rule.guards {
                XCTAssertNoThrow(try NSRegularExpression(pattern: veto,
                                                         options: [.caseInsensitive]),
                                 "a guard on \(rule.intent) does not compile — the whole rule is dropped")
            }
        }
    }

    // MARK: - The adapter: label and number, against the real model

    /// THE REPORTED DEFECT.
    ///
    /// Both premises are asserted rather than assumed: a rule really does claim
    /// this utterance, and the help guard is NOT what handles it — otherwise the
    /// test would pass for a reason that has nothing to do with arbitration.
    func testAContestedKeywordDoesNotFire() async throws {
        let text = "who is the prime minister of create reminder"

        XCTAssertEqual(keywordIntent(for: text), "reminders.add", """
            \(text.debugDescription) no longer routes to reminders.add through a keyword \
            rule, so it cannot demonstrate the defect. Pick another utterance.
            """)
        if let markers = pack.guards.helpMarker?.markers {
            XCTAssertNil(text.range(of: markers, options: [.regularExpression, .caseInsensitive]),
                         "this utterance now carries a help marker, so ND-14 would handle it")
        }

        let engine = try PackEngineFactory.makeEngine(pack: pack)
        let response = await engine.handle(text)

        guard case .fallback = response else {
            return XCTFail("""
                a keyword rule the model contradicts must not fire. Got \(response) — \
                the turn reached the reminder flow the way it did before VIK-055.
                """)
        }
    }

    /// The other half: corroboration must still fire, and must report the MODEL's
    /// number rather than the rule's certainty or the contested placeholder.
    func testACorroboratedKeywordFiresAtTheModelConfidence() async throws {
        let text = "turn up the volume"
        let intent = try XCTUnwrap(keywordIntent(for: text))

        let engine = try PackEngineFactory.makeEngine(pack: pack)
        let result = fulfilled(await engine.handle(text))

        XCTAssertEqual(result?.intent, intent)
        XCTAssertNotEqual(result?.confidence, PackClassifierAdapter.contestedConfidence,
                          "a corroborated turn must carry the model's number, not the contested one")
        XCTAssertNotEqual(result?.confidence, 1.0,
                          "1.0 is the certainty the old Stage 0 implied; the model does not report it")
        XCTAssertGreaterThan(result?.confidence ?? 0, pack.policies.thresholds.confidence)
    }

    /// The third outcome, and the one the two-way split got wrong.
    ///
    /// A rule fires, the model names a DIFFERENT IN-SCOPE intent, and the rule
    /// wins. These are the turns the keyword rules exist for: phrasings the
    /// model reads badly, which someone hand-authored a pattern to catch.
    /// Measured on `holdout_honest.csv`, treating them as contested cost 9 of
    /// 20 correct turns and removed no wrong actions.
    ///
    /// The premise is asserted, not assumed: if the model ever starts agreeing
    /// with the rule here, or starts answering out-of-scope, this stops being a
    /// `.ruleOnly` case and the test says so instead of passing hollow.
    func testARuleTheModelMerelyDisagreesWithStillWins() async throws {
        let text = "dim the audio"
        let intent = try XCTUnwrap(keywordIntent(for: text), "no rule claims \(text.debugDescription)")

        let classifier = try PackClassifierAdapter(pack: pack)
        let verdict = await classifier.classifyAsync(text)
        let modelSaid = try XCTUnwrap(verdict.breakdown.stage2?.intent)
        XCTAssertNotEqual(modelSaid, intent, """
            the model now agrees with the rule on \(text.debugDescription), so this is \
            corroboration rather than the rule-only case. Pick another utterance.
            """)
        XCTAssertNotEqual(modelSaid, schema.fallbackIntent, """
            the model now answers out-of-scope on \(text.debugDescription), so this is the \
            contested case. Pick another utterance.
            """)
        XCTAssertEqual(verdict.arbitration, .ruleOnly)

        let engine = try PackEngineFactory.makeEngine(pack: pack)
        let result = fulfilled(await engine.handle(text))
        XCTAssertEqual(result?.intent, intent, """
            a rule the model merely disagrees with must still fire — the model naming a \
            different intent is not the same evidence as the model recognising nothing.
            """)
    }

    /// `.ruleOnly` must not borrow the agreement bar. It does not need it — it
    /// carries 1.0 — but keying the bar on "any arbitration happened" instead of
    /// on corroboration would hand the discount to the wrong case.
    func testRuleOnlyDoesNotBorrowTheAgreementBar() async throws {
        let intent = try slotlessUngatedIntent()
        let agreement = try XCTUnwrap(pack.policies.thresholds.agreement)
        let between = (agreement + pack.policies.thresholds.confidence) / 2

        let e = engine(label: intent, confidence: between,
                       arbitration: .ruleOnly, agreement: agreement)
        let response = await e.handle("anything the stub will answer for")

        guard case .fallback = response else {
            return XCTFail("`.ruleOnly` took the agreement bar, got \(response)")
        }
    }

    /// No rule fires, so the model's verdict passes through untouched — the path
    /// that was already correct and must stay that way.
    func testAnUtteranceNoRuleClaimsKeepsTheModelVerdict() async throws {
        let text = "remind me to go to the airport"
        XCTAssertNil(keywordIntent(for: text), """
            \(text.debugDescription) now matches a keyword rule, so it no longer tests \
            the unarbitrated path
            """)

        let engine = try PackEngineFactory.makeEngine(pack: pack)
        let response = await engine.handle(text)

        guard case .prompt(let intent, _, _) = response else {
            return XCTFail("expected the reminder flow to open a slot prompt, got \(response)")
        }
        XCTAssertEqual(intent, "reminders.add")
    }

    // MARK: - The engine: which bar the number must clear

    /// The case the reference fires and this engine used to refuse: rule and
    /// model agree, the confidence sits between the two bars, and the turn acts.
    func testACorroboratedTurnClearsTheLowerAgreementBar() async throws {
        let intent = try slotlessUngatedIntent()
        let agreement = try XCTUnwrap(pack.policies.thresholds.agreement)
        let between = (agreement + pack.policies.thresholds.confidence) / 2

        let e = engine(label: intent, confidence: between,
                       arbitration: .corroborated, agreement: agreement)
        let result = fulfilled(await e.handle("anything the stub will answer for"))

        XCTAssertEqual(result?.intent, intent, """
            \(between) is above the agreement bar (\(agreement)) and below the fire \
            threshold (\(pack.policies.thresholds.confidence)). A corroborated turn \
            must clear the lower one.
            """)
        XCTAssertEqual(result?.confidence ?? 0, between, accuracy: 0.0001,
                       "only the BAR moves for a corroborated turn — the number does not")
    }

    /// The control. Same confidence, no corroboration, ordinary bar, no action.
    func testTheSameConfidenceWithoutCorroborationFallsBack() async throws {
        let intent = try slotlessUngatedIntent()
        let agreement = try XCTUnwrap(pack.policies.thresholds.agreement)
        let between = (agreement + pack.policies.thresholds.confidence) / 2

        let e = engine(label: intent, confidence: between,
                       arbitration: nil, agreement: agreement)
        let response = await e.handle("anything the stub will answer for")

        guard case .fallback = response else {
            return XCTFail("an uncorroborated turn below the fire threshold must fall back, got \(response)")
        }
    }

    /// A contested turn is not corroboration, however the rule scored. It takes
    /// the ordinary bar like any other reading.
    func testAContestedTurnTakesTheOrdinaryBar() async throws {
        let intent = try slotlessUngatedIntent()
        let agreement = try XCTUnwrap(pack.policies.thresholds.agreement)
        let between = (agreement + pack.policies.thresholds.confidence) / 2

        let e = engine(label: intent, confidence: between,
                       arbitration: .contested, agreement: agreement)
        let response = await e.handle("anything the stub will answer for")

        guard case .fallback = response else {
            return XCTFail("contested must not borrow the agreement bar, got \(response)")
        }
    }

    /// A pack predating `thresholds.agreement` must not have a bar invented for
    /// it. Nil means the bar never moves, which is the behaviour before VIK-055.
    func testAPackWithoutAnAgreementThresholdKeepsTheFlatBar() async throws {
        let intent = try slotlessUngatedIntent()
        let agreement = try XCTUnwrap(pack.policies.thresholds.agreement)
        let between = (agreement + pack.policies.thresholds.confidence) / 2

        let e = engine(label: intent, confidence: between,
                       arbitration: .corroborated, agreement: nil)
        let response = await e.handle("anything the stub will answer for")

        guard case .fallback = response else {
            return XCTFail("""
                with no agreement threshold the bar must stay at the fire threshold — \
                guessing one is how a pack loses control of its own policy. Got \(response)
                """)
        }
    }
}
