// HelpMarkerGuardTests.swift
// VoiceAIKitTests
//
// ND-14 — asking HOW to use a feature must never TRIGGER it.
//
// `runtime/guards.json` has shipped in every pack this loader has ever read,
// and nothing consumed it: `PackGuards` was decoded, validated for dangling
// intents, and never applied. So on a device "how do I turn down the loudness"
// classified as `Cmd.VolumeDecrease` and TURNED THE VOLUME DOWN, while the
// reference engine showed help. Same pack, same words.
//
// Scale, measured on the product team's 1492 help phrases rather than guessed:
// the guard corrects 72 of them, 36 being volume changes that would otherwise
// have happened on the device, and regresses none.
//
// Every scripted number below was READ OFF the reference engine on the vendored
// pack, not invented — see `docs/help-intent-misrouting.md` in the Python repo.

import XCTest
@testable import VoiceAIKit

/// Returns the label it is told to, and answers `calibratedConfidence` from a
/// scripted distribution — the half a naive stub omits, and the half the
/// guard's usefulness depends on.
private actor GuardStubClassifier: IntentClassifying {

    private let label: String
    private let confidence: Double
    private let distribution: [String: Double]

    init(label: String, confidence: Double, distribution: [String: Double] = [:]) {
        self.label = label
        self.confidence = confidence
        self.distribution = distribution
    }

    func classifyAsync(_ text: String) async -> ClassificationResult {
        ClassificationResult(
            label: label, confidence: confidence, semanticRescue: false,
            breakdown: ClassificationBreakdown(
                winningStage: 2,
                stage2: ClassificationBreakdown.StageResult(
                    stage: 2, intent: label, confidence: confidence),
                stage3: nil))
    }

    func calibratedConfidence(for intent: String) async -> Double? { distribution[intent] }

    func warmUp() async {}
    func loadStage3() async {}
    func releaseStage3() async {}
    func oovRatio(_ text: String) async -> Double { 0 }
}

final class HelpMarkerGuardTests: XCTestCase {

    private var pack: ResolvedPack!
    private var schema: NLUSchema!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pack = try PackTestSupport.loadPack()
        schema = try PackEngineFactory.schema(from: pack)
    }

    private func makeEngine(label: String,
                            confidence: Double,
                            distribution: [String: Double] = [:],
                            withGuard: Bool = true) -> NLUEngine {
        NLUEngine(
            schema: schema,
            classifier: GuardStubClassifier(label: label, confidence: confidence,
                                            distribution: distribution),
            entities: PackSlotResolver(pack: pack),
            uncertain: [],
            noIdioms: [],
            carriers: pack.lexicon.carriers,
            interruptThreshold: pack.policies.thresholds.interrupt,
            maxSlotAttempts: pack.policies.limits.maxSlotAttempts,
            // The OOV guard is a separate turn-killer; this suite is about ND-14
            // alone, and leaving it on would make a failure ambiguous.
            oovReject: nil,
            oovBypass: nil,
            leadingConnectors: pack.lexicon.leadingConnectors,
            confirmationGates: PackEngineFactory.confirmationGates(from: pack),
            helpMarkerPattern: withGuard ? pack.guards.helpMarker?.markers : nil,
            helpPairs: withGuard ? (pack.guards.helpMarker?.pairs ?? [:]) : [:])
    }

    private func fulfilled(_ response: NLUResponse) -> (intent: String, confidence: Double)? {
        guard case .fulfill(let intent, _, _, _, let conf, _, _) = response else { return nil }
        return (intent, conf)
    }

    // MARK: The pack's own data

    /// The premise. The pack shipped this unread for long enough that its
    /// absence would go unnoticed, so it is asserted rather than assumed.
    func testThePackShipsTheGuard() throws {
        let marker = try XCTUnwrap(pack.guards.helpMarker,
                                   "runtime/guards.json carries no help_marker")
        XCTAssertFalse(marker.markers.isEmpty)
        XCTAssertFalse(marker.pairs.isEmpty)
        for (command, help) in marker.pairs {
            XCTAssertNotNil(schema.intents[command], "\(command) is not an intent in this pack")
            XCTAssertNotNil(schema.intents[help], "\(help) is not an intent in this pack")
            XCTAssertNotEqual(command, help, "\(command) is paired with itself")
        }
    }

    /// The pattern this platform must be able to compile. `NSRegularExpression`
    /// is not Python's `re`; a pattern that fails here disables the guard
    /// silently, so the failure belongs in a test rather than in the field.
    func testTheMarkerPatternCompilesOnThisPlatform() throws {
        let pattern = try XCTUnwrap(pack.guards.helpMarker?.markers)
        XCTAssertNoThrow(try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
    }

    // MARK: The keyword path — a rule must not carry a question to a command

    /// The path that made the device act.
    ///
    /// Stage 0 used to return before the classifier ran, so a keyword rule
    /// carried a help question straight to a command at an implied confidence of
    /// 1.0. VIK-055 removed Stage 0, so this now runs through the REAL
    /// `PackClassifierAdapter` — which is the only way it can still prove
    /// anything: a stub classifier IS the classifier, so a stubbed version of
    /// this test would assert that the stub returns what it was told to.
    ///
    /// Every one of these is CONTESTED under arbitration — the rule says
    /// `Cmd.*`, the model says `Help_*` — which is the exact shape the guard has
    /// to survive: the turn arrives at 0.60, the guard redirects to the sibling,
    /// and the re-read pulls the model's own probability for THAT intent back up
    /// over the fire threshold. Without the re-read every one of these would fall
    /// back and the guard would look broken while behaving correctly.
    func testAKeywordRoutedHelpAskIsNotSmuggledPastTheGuard() async throws {
        let cases: [(text: String, command: String, help: String)] = [
            ("can you show me transcribe user guide",      "Cmd.TranscribeStart",  "Help_Transcribe"),
            ("hearing aids transcribe help",               "Cmd.TranscribeStart",  "Help_Transcribe"),
            ("how do i turn down the loudness on my aid?", "Cmd.VolumeDecrease",   "Help_Volume"),
            ("hearing aids translate guide",               "Cmd.TranslationStart", "Help_Translate"),
            ("how do i set a reminder",                    "reminders.add",        "Help_Reminder"),
        ]

        let engine = try PackEngineFactory.makeEngine(pack: pack)

        for c in cases {
            // Premise 1: a keyword rule really does claim this utterance. Asserted,
            // not assumed — a rule change would otherwise turn this into a no-op.
            let routed = pack.keywordRulesByTier.first { rule in
                c.text.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil
                    && !rule.guards.contains {
                        c.text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
                    }
            }
            XCTAssertEqual(routed?.intent, c.command, """
                \(c.text.debugDescription) no longer routes to \(c.command) through a \
                keyword rule, so it cannot demonstrate what this test is about. Pick another.
                """)
            // Premise 2: the pack pairs that command with this help intent.
            XCTAssertEqual(pack.guards.helpMarker?.pairs[c.command], c.help)

            let result = fulfilled(await engine.handle(c.text))

            XCTAssertEqual(result?.intent, c.help, """
                \(c.text.debugDescription) reached \(c.command) — a keyword rule carried a \
                question past the guard and the device acts on it.
                """)
            XCTAssertGreaterThanOrEqual(result?.confidence ?? 0, schema.confidenceThreshold, """
                \(c.text.debugDescription) redirected to \(c.help) but kept a confidence under \
                the fire threshold, which reaches the user as "not understood" — the \
                calibrated re-read is what this asserts.
                """)
            await engine.reset()
        }
    }

    // MARK: The classifier path — redirect, and re-read the confidence

    /// The other half, on an utterance no keyword rule claims, so the turn
    /// genuinely reaches the classifier.
    ///
    /// The scripted confidences are the shape that matters: the model's answer
    /// (0.600) is BELOW the pack's fire threshold and the sibling's (0.931) is
    /// above. If the redirect kept the blocked number the turn would fall back,
    /// which is precisely how 11 of 12 guarded turns were lost on the holdout.
    func testARedirectRereadsTheConfidence() async throws {
        let text = "how do i use the transcribe feature?"
        XCTAssertNil(pack.keywordRules.first { rule in
            text.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }, "\(text) now matches a keyword rule, so it no longer tests the classifier path")

        let engine = makeEngine(label: "Cmd.TranscribeStart", confidence: 0.600,
                                distribution: ["Help_Transcribe": 0.999])
        let result = fulfilled(await engine.handle(text))

        XCTAssertEqual(result?.intent, "Help_Transcribe", "the guard did not redirect")
        XCTAssertEqual(result?.confidence ?? 0, 0.999, accuracy: 0.0001, """
            the turn kept the BLOCKED prediction's confidence. It is compared \
            against the fire threshold next, so the turn is deflected to the \
            fallback and the guard blocks the wrong action AND the right one.
            """)
    }

    /// Without the re-read the turn is lost. Same inputs, distribution withheld
    /// — which is what a classifier that keeps none reports.
    func testWithoutADistributionTheTurnKeepsItsOwnConfidence() async throws {
        let engine = makeEngine(label: "Cmd.TranscribeStart", confidence: 0.600)
        let response = await engine.handle("how do i use the transcribe feature?")

        guard case .fallback = response else {
            return XCTFail("""
                expected the fallback: 0.600 is below this pack's fire threshold \
                and no distribution was available to re-read. Got \(response)
                """)
        }
    }

    // MARK: Controls

    /// A real command must reach its action untouched, or the guard is breakage
    /// with a safety story attached. Neither utterance carries a marker.
    func testARealCommandIsNotRedirected() async throws {
        for (text, intent) in [("start transcription", "Cmd.TranscribeStart"),
                               ("turn up the volume", "Cmd.VolumeIncrease")] {
            let engine = makeEngine(label: intent, confidence: 0.95)
            let result = fulfilled(await engine.handle(text))
            XCTAssertEqual(result?.intent, intent, "a plain command was redirected to help")
        }
    }

    /// An intent with no help sibling is never redirected, however phrased.
    /// Read-only queries are unpaired ON PURPOSE upstream — "how many steps" is
    /// a real question, not a help ask.
    func testAnUnpairedIntentIsNeverRedirected() async throws {
        let paired = Set(pack.guards.helpMarker?.pairs.keys.map { $0 } ?? [])
        // Slotless and unconfirmed, so the turn ends in `.fulfill` and the
        // assertion is about the intent rather than about which prompt fired.
        let unpaired = try XCTUnwrap(
            schema.intents.keys
                .filter { !paired.contains($0) && !$0.hasPrefix("Help_") }
                .filter { schema.intents[$0]?.slots.isEmpty == true }
                .filter { schema.intents[$0]?.followup == nil }
                .sorted().first,
            "every unpaired intent has slots or a confirmation; choose the case by hand")

        let engine = makeEngine(label: unpaired, confidence: 0.95)
        let result = fulfilled(await engine.handle("how do i use this"))

        XCTAssertEqual(result?.intent, unpaired,
                       "an intent with no help sibling was redirected anyway")
    }

    /// A pack with no guard behaves exactly as it did before this existed.
    func testAPackWithoutTheGuardIsUnchanged() async throws {
        let engine = makeEngine(label: "Cmd.TranscribeStart", confidence: 0.95,
                                withGuard: false)
        let result = fulfilled(await engine.handle("how do i use the transcribe feature?"))

        XCTAssertEqual(result?.intent, "Cmd.TranscribeStart",
                       "no guard data must mean no redirect, not a crash or a default")
    }
}
