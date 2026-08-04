// ConfirmationAndSlotFlowTests.swift
// VoiceIntentKitTests
//
// VIK-021 and VIK-023 — the turn-by-turn behaviour of a gated intent.
//
// The classifier is stubbed so confidence is an input rather than a
// measurement: every case here is about what the engine does WITH a confidence,
// and a real model would make these tests depend on the head's calibration.
// Everything else — schema, gates, prompts, entity tables, carriers — comes from
// the vendored pack.

import XCTest
@testable import VoiceIntentKit

// MARK: - Stub

/// Returns whatever it is told to. `IntentClassifying` is an `Actor` protocol,
/// so this is an actor too.
private actor StubClassifier: IntentClassifying {

    private var label: String
    private var confidence: Double

    init(label: String, confidence: Double) {
        self.label = label
        self.confidence = confidence
    }

    func classifyAsync(_ text: String) async -> ClassificationResult {
        ClassificationResult(
            label: label,
            confidence: confidence,
            semanticRescue: false,
            breakdown: ClassificationBreakdown(
                winningStage: 2,
                stage2: ClassificationBreakdown.StageResult(
                    stage: 2, intent: label, confidence: confidence),
                stage3: nil))
    }

    func genaiURL(for text: String) -> URL { URL(string: "https://example.invalid/q")! }
    func warmUp() async {}
    func loadStage3() async {}
    func releaseStage3() async {}
}

// MARK: - Tests

final class ConfirmationAndSlotFlowTests: XCTestCase {

    private var pack: ResolvedPack!

    /// The intent under test: the only gated intent in `pack-en` with required
    /// slots, and therefore the only place VIK-021 destroyed data.
    private let reminder = "reminders.task.create"

    override func setUpWithError() throws {
        try super.setUpWithError()
        pack = try PackTestSupport.loadPack()
    }

    /// An engine wired exactly as `PackEngineFactory` wires one, but with a
    /// stubbed classifier. Kept in step with the factory deliberately: if the
    /// factory's wiring changes and this does not, these tests stop describing
    /// production and start describing themselves.
    private func makeEngine(confidence: Double, label: String? = nil) -> NLUEngine {
        NLUEngine(
            schema: PackEngineFactory.schema(from: pack),
            classifier: StubClassifier(label: label ?? reminder, confidence: confidence),
            entities: PackSlotResolver(pack: pack),
            uncertain: [],
            noIdioms: [],
            carriers: pack.lexicon.carriers,
            leadingConnectors: pack.lexicon.leadingConnectors,
            confirmationGates: PackEngineFactory.confirmationGates(from: pack))
    }

    // MARK: The gate itself

    func testGateBoundariesAreHalfOpen() {
        let gate = ConfirmationGate.whenAmbiguous(floor: 0.55, ceiling: 0.91)

        XCTAssertFalse(gate.fires(confidence: 0.54))
        XCTAssertTrue(gate.fires(confidence: 0.55), "the floor is inclusive")
        XCTAssertTrue(gate.fires(confidence: 0.90))
        XCTAssertFalse(gate.fires(confidence: 0.91), "`uncertain_confirm_below` means below")
        XCTAssertFalse(gate.fires(confidence: 0.99))

        XCTAssertTrue(ConfirmationGate.always.fires(confidence: 0.01))
        XCTAssertFalse(ConfirmationGate.never.fires(confidence: 0.99))
    }

    /// The gates must come from `policies.confirmation`, not from whether a
    /// workflow happens to carry a `confirmation` block.
    func testGatesAreReadFromThePackPolicy() throws {
        let gates = PackEngineFactory.confirmationGates(from: pack)
        let band = try XCTUnwrap(pack.uncertainConfirmBand,
                                 "pack-en carries uncertain_confirm_below/_floor")

        XCTAssertEqual(gates[reminder],
                       .whenAmbiguous(floor: band.floor, ceiling: band.ceiling))

        var never = 0, ambiguous = 0, always = 0
        for (_, gate) in gates {
            switch gate {
            case .never: never += 1
            case .whenAmbiguous: ambiguous += 1
            case .always: always += 1
            }
        }
        XCTAssertEqual(gates.count, pack.intents.count, "every intent gets a gate")
        XCTAssertEqual(ambiguous, 14, "pack-en gates 14 intents on ambiguity")
        XCTAssertEqual(never, pack.intents.count - 14)
        XCTAssertEqual(always, 0)
    }

    // MARK: Confident — no confirmation, straight to slots

    /// The case that started this: a confident reminder must not ask permission,
    /// must keep the name it was given, and must ask for the time.
    func testConfidentReminderSkipsConfirmationAndCollectsSlots() async throws {
        let engine = makeEngine(confidence: 0.95)
        let response = await engine.handle("set a reminder to go to the airport")

        guard case .prompt(let intent, let question, let filled) = response else {
            return XCTFail("expected a slot prompt, got \(response)")
        }
        XCTAssertEqual(intent, reminder)
        XCTAssertEqual(filled["name"], "go to the airport",
                       "the name is in the opening utterance — asking for it again is the bug")
        XCTAssertNil(filled["date_time"], "no time was given")
        XCTAssertEqual(question,
                       pack.responses["reminders.task.create.ask_date_time"],
                       "the outstanding slot is the time, and the prompt is the pack's")
    }

    /// The other phrasing, through the carrier the pack has always shipped.
    func testPackCarriersHandleTheRemindMePhrasing() async throws {
        let engine = makeEngine(confidence: 0.95)
        let response = await engine.handle("remind me to go to the airport")

        guard case .prompt(_, _, let filled) = response else {
            return XCTFail("expected a slot prompt, got \(response)")
        }
        XCTAssertEqual(filled["name"], "go to the airport")
    }

    /// VIK-022, now closed at the source.
    ///
    /// The carrier was never missing from CONTENT — it failed the compiler's
    /// portable-regex check because of a negative lookahead, and was dropped
    /// into a log line on every build. The rewritten form carries no lookahead,
    /// which is the property worth asserting: a pattern that cannot be expressed
    /// in the subset cannot reach a device, however correct it looks.
    func testTheSetReminderCarrierShipsAndIsPortable() throws {
        let carriers = pack.lexicon.carriers
        XCTAssertTrue(carriers.contains { $0.contains("reminder|alarm") },
                      "the set-a-reminder carrier must be in the pack, not in host code")
        XCTAssertFalse(carriers.contains { $0.contains("(?!") },
                       "negative lookahead is outside the portable subset and gets silently dropped")
    }

    /// VIK-017, now closed at the source.
    ///
    /// `open` reaches the runtime through TWO steps that each used to lose it:
    /// the compiler's projection, and `BundleDataLoader`'s flatten. Asserting
    /// the flag on `ResolvedPack` covers both — reading it off the raw section
    /// would pass while the join still dropped it, which is exactly how VIK-003
    /// happened.
    func testOpenFlagSurvivesFromContentToResolvedPack() throws {
        XCTAssertTrue(pack.openEntities.contains("remind"),
                      "remind is open in content; losing it anywhere stops free-text slots filling")
        XCTAssertFalse(pack.openEntities.contains("memory"),
                       "memory is a closed set — the flag must be read, not assumed")
    }

    // MARK: Ambiguous — confirm, then continue

    func testAmbiguousReminderConfirmsFirst() async throws {
        let engine = makeEngine(confidence: 0.80)
        let response = await engine.handle("set a reminder to go to the airport")

        guard case .confirm(let intent, _, let question) = response else {
            return XCTFail("expected a confirmation, got \(response)")
        }
        XCTAssertEqual(intent, reminder)
        XCTAssertEqual(question, pack.responses["reminders.task.create.confirm"])
    }

    /// VIK-021's actual damage. "Yes" used to fulfil with `parameters: [:]` —
    /// a reminder with no name and no time, reported as success.
    func testYesContinuesSlotFillingInsteadOfFulfillingEmpty() async throws {
        let engine = makeEngine(confidence: 0.80)

        let confirm = await engine.handle("set a reminder to go to the airport")
        guard case .confirm = confirm else {
            return XCTFail("expected a confirmation, got \(confirm)")
        }

        let afterYes = await engine.handle("yes")

        if case .fulfill(_, _, let parameters, _, _, _, _) = afterYes {
            XCTFail("""
                fulfilled straight from the confirmation with parameters \(parameters) — \
                this is VIK-021: a reminder created with no name and no time
                """)
        }
        guard case .prompt(let intent, let question, let filled) = afterYes else {
            return XCTFail("expected a slot prompt after yes, got \(afterYes)")
        }
        XCTAssertEqual(intent, reminder)
        XCTAssertEqual(filled["name"], "go to the airport",
                       "slots staged before the confirmation must survive it")
        XCTAssertEqual(question, pack.responses["reminders.task.create.ask_date_time"])
    }

    /// The whole flow, as a user would walk it.
    func testAmbiguousReminderCompletesEndToEnd() async throws {
        let engine = makeEngine(confidence: 0.80)

        _ = await engine.handle("set a reminder to go to the airport")
        _ = await engine.handle("yes")
        let done = await engine.handle("tomorrow at 5pm")

        guard case .fulfill(let intent, let action, let parameters, let message, _, _, _) = done else {
            return XCTFail("expected fulfilment, got \(done)")
        }
        XCTAssertEqual(intent, reminder)
        XCTAssertEqual(action, "reminders.task.create")
        XCTAssertEqual(parameters["name"], "go to the airport")
        XCTAssertNotNil(parameters["date_time"], "the time answer must be stored")
        XCTAssertEqual(message, pack.responses["reminders.task.create.done"])

        let collecting = await engine.isCollecting
        XCTAssertFalse(collecting, "the flow is finished")
    }

    // MARK: Declining

    func testNoCancelsAndClearsTheFlow() async throws {
        let engine = makeEngine(confidence: 0.80)

        _ = await engine.handle("set a reminder to go to the airport")
        let declined = await engine.handle("no")

        guard case .fulfill(_, _, _, let message, _, _, _) = declined else {
            return XCTFail("expected the cancellation, got \(declined)")
        }
        XCTAssertEqual(message, pack.responses["sys.confirm.cancelled"])

        let collecting = await engine.isCollecting
        XCTAssertFalse(collecting, "declining must not leave a half-filled flow armed")
    }

    /// VIK-023. `negation_cues` was wired into `uncertain`, and the check is a
    /// substring test — so "cancel" matched the cue "cancel", `yesNo` returned
    /// nil, and the engine re-asked the same question. Seven of the pack's
    /// twelve decline words behaved this way; only "no", "nah", "negative",
    /// "nope" and "no thanks" worked.
    func testEveryDeclineWordInThePackActuallyDeclines() async throws {
        for word in pack.lexicon.negative {
            let engine = makeEngine(confidence: 0.80)
            _ = await engine.handle("set a reminder to go to the airport")
            let response = await engine.handle(word)

            guard case .fulfill(_, _, _, let message, _, _, _) = response else {
                return XCTFail("'\(word)' did not decline — got \(response)")
            }
            XCTAssertEqual(message, pack.responses["sys.confirm.cancelled"], word)
        }
    }

    func testEveryAcceptWordInThePackActuallyAccepts() async throws {
        for word in pack.lexicon.affirmative {
            let engine = makeEngine(confidence: 0.80)
            _ = await engine.handle("set a reminder to go to the airport")
            let response = await engine.handle(word)

            guard case .prompt = response else {
                return XCTFail("'\(word)' did not accept — got \(response)")
            }
        }
    }
}
