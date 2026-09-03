// ConfirmationAndSlotFlowTests.swift
// VoiceAIKitTests
//
// VIK-021 and VIK-023 — the turn-by-turn behaviour of a gated intent.
//
// The classifier is stubbed so confidence is an input rather than a
// measurement: every case here is about what the engine does WITH a confidence,
// and a real model would make these tests depend on the head's calibration.
// Everything else — schema, gates, prompts, entity tables, carriers — comes from
// the vendored pack.

import XCTest
@testable import VoiceAIKit

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

    func warmUp() async {}
    func loadStage3() async {}
    func releaseStage3() async {}
}

// MARK: - Tests

final class ConfirmationAndSlotFlowTests: XCTestCase {

    private var pack: ResolvedPack!
    private var schema: NLUSchema!

    /// The intent under test: the pack's intent with required slots, which is
    /// where VIK-021 destroyed data. Resolved from the pack — see
    /// `PackTestSupport.intentWithRequiredSlots`.
    private var reminder: String!

    /// Every expected string comes from the pack through the schema, never from a
    /// literal in this file. The literals are what broke when the taxonomy moved:
    /// `reminders.task.create.ask_date_time` is not a key any pack has any more,
    /// and a test asserting against one is testing its own memory.
    private var askDateTime: String? { slotPrompt("date_time") }
    private var confirmPrompt: String? { schema.intents[reminder]?.followup?.prompt }
    private var fulfilment: String? { schema.intents[reminder]?.fulfillment }
    private var action: String? { schema.intents[reminder]?.action }

    /// Routes through Stage 0: `keywords/en.json` carries
    /// `\b(set|create|add|make)\b.{0,20}\breminder\b`, so this utterance reaches the
    /// intent WITHOUT the classifier — and, today, without the confirmation gate.
    private let keywordRouted = "set a reminder to go to the airport"

    /// Reaches the CLASSIFIER: no keyword rule matches this phrasing, so the stub's
    /// confidence and the injected gate are what decide the turn.
    ///
    /// Every confirmation test below must use this one. They used `keywordRouted` and
    /// therefore never reached a gate at all: four went red for the obvious reason, and
    /// three stayed GREEN while testing nothing — a "yes" answered a slot prompt rather
    /// than a confirmation, and the assertion could not tell the difference.
    private let classifierRouted = "remind me to go to the airport"

    private func slotPrompt(_ name: String) -> String? {
        schema.intents[reminder]?.slots.first { $0.name == name }?.prompt
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        pack = try PackTestSupport.loadPack()
        schema = PackEngineFactory.schema(from: pack)
        // The reminder shape: a free-text name plus a time. `Cmd.MemoryChange` also
        // has a required slot, so "has required slots" alone selects the wrong flow.
        reminder = try PackTestSupport.intent(requiringSlots: ["name", "date_time"], in: pack)
    }

    /// An engine wired exactly as `PackEngineFactory` wires one, but with a
    /// stubbed classifier. Kept in step with the factory deliberately: if the
    /// factory's wiring changes and this does not, these tests stop describing
    /// production and start describing themselves.
    /// - Parameter gate: the confirmation gate for `reminder`. `nil` uses the
    ///   pack's own policy.
    ///
    ///   It has to be injectable now, and that is a statement about the pack rather
    ///   than about the test. `pack-en` today gates exactly one intent (`always`,
    ///   `Cmd.SendMessage`) and that intent has no slots, while the intent that has
    ///   slots is `never` — so no pack intent is both gated AND slot-bearing, and
    ///   the confirm-then-collect flow VIK-021 broke cannot be reached through the
    ///   pack at all. The engine behaviour is still real and still worth guarding,
    ///   so the gate is supplied here instead of pretending the pack supplies it.
    private func makeEngine(confidence: Double,
                            label: String? = nil,
                            gate: ConfirmationGate? = nil) -> NLUEngine {
        var gates = PackEngineFactory.confirmationGates(from: pack)
        if let gate { gates[reminder] = gate }
        return NLUEngine(
            schema: schema,
            classifier: StubClassifier(label: label ?? reminder, confidence: confidence),
            entities: PackSlotResolver(pack: pack),
            uncertain: [],
            noIdioms: [],
            carriers: pack.lexicon.carriers,
            interruptThreshold: pack.policies.thresholds.interrupt,
            maxSlotAttempts: pack.policies.limits.maxSlotAttempts,
            leadingConnectors: pack.lexicon.leadingConnectors,
            confirmationGates: gates)
    }

    /// The band `pack-en` no longer carries. Fixed here so the half-open boundary
    /// behaviour stays covered; the pack's own gating is asserted separately in
    /// `testGatesAreReadFromThePackPolicy`.
    private static let testBand = ConfirmationGate.whenAmbiguous(floor: 0.55, ceiling: 0.91)

    /// The premise the confirmation tests rest on. A keyword rule added for the
    /// `remind me` phrasing would route those tests around the gate again, and they
    /// would pass while asserting nothing.
    func testTheTwoUtterancesTakeTheRoutesTheseTestsAssume() throws {
        let rules = pack.keywordRules.map(\.pattern)
        func matches(_ text: String) -> Bool {
            rules.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        XCTAssertTrue(matches(keywordRouted), "\(keywordRouted) must reach Stage 0")
        XCTAssertFalse(matches(classifierRouted), """
            \(classifierRouted) now matches a keyword rule, so the confirmation tests \
            below bypass the gate and prove nothing. Pick another phrasing for them.
            """)
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
    /// workflow happens to carry a `confirmation` block. `reminders.add` is the
    /// proof: it ships a `confirmation` block and a `never` policy, and the policy
    /// is what must win.
    ///
    /// This used to require `uncertain_confirm_below`/`_floor` from the pack and
    /// assert that 14 intents gated on ambiguity. Both are gone, deliberately —
    /// the compiler moved to one fire threshold with no confidence-driven
    /// confirmation. So the assertion is now the pack's actual shape, and the
    /// consistency rule that matters: a pack may omit the band only while no
    /// intent asks for `when_ambiguous`.
    func testGatesAreReadFromThePackPolicy() throws {
        let gates = PackEngineFactory.confirmationGates(from: pack)
        XCTAssertEqual(gates.count, pack.intents.count, "every intent gets a gate")

        for (id, gate) in gates {
            switch pack.confirmationPolicy(for: id) {
            case .always: XCTAssertEqual(gate, .always, id)
            case .never:  XCTAssertEqual(gate, .never, id)
            case .whenAmbiguous:
                XCTAssertNotNil(pack.uncertainConfirmBand, """
                    \(id) asks for when_ambiguous but the pack carries no band — the \
                    runtime can only degrade it to `never`, so the intent acts without \
                    confirming. A pack must ship the band or stop asking for it.
                    """)
            }
        }

        let ambiguous = pack.intents.keys.filter {
            pack.confirmationPolicy(for: $0) == .whenAmbiguous
        }
        if pack.uncertainConfirmBand == nil {
            XCTAssertTrue(ambiguous.isEmpty, """
                No confirmation band, but \(ambiguous.sorted()) request when_ambiguous.
                """)
        }
    }

    /// VIK-036 — a keyword rule bypasses the CLASSIFIER, never the POLICY.
    ///
    /// Stage 0 used to go straight to `advanceSlots`, so an intent reached through a
    /// keyword rule never met its confirmation gate. `pack-en` is the worst case for
    /// that: `Cmd.SendMessage` is the ONE intent it gates `always`, and it ships four
    /// keyword rules — `^ptt$`, `^push to talk$`, and two `send…message` patterns. A
    /// message went out without asking, on the only intent the pack says to always ask
    /// about.
    ///
    /// The premise is asserted rather than assumed: if this utterance stops reaching an
    /// always-gated intent through Stage 0, the test says so instead of passing hollow.
    func testAKeywordRoutedAlwaysGatedIntentStillConfirms() async throws {
        let utterance = "send a message to mom"

        func matches(_ pattern: String) -> Bool {
            utterance.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let routed = pack.keywordRules.first { rule in
            matches(rule.pattern) && !rule.guards.contains(where: matches)
        }
        let intent = try XCTUnwrap(routed?.intent,
                                   "\(utterance) no longer matches any keyword rule")
        try XCTSkipUnless(pack.confirmationPolicy(for: intent) == .always,
                          "\(intent) is no longer gated `always`, so this utterance cannot "
                          + "demonstrate the defect — find another always-gated intent with a "
                          + "keyword rule, or retire this test with the policy that motivated it.")

        let engine = makeEngine(confidence: 0.99, label: intent)
        let response = await engine.handle(utterance)

        guard case .confirm(let confirmed, _, _, _) = response else {
            return XCTFail("""
                \(intent) is policy `always` and was reached through a keyword rule, but \
                the engine returned \(response) — it acted without asking (VIK-036).
                """)
        }
        XCTAssertEqual(confirmed, intent)
    }

    // MARK: Confident — no confirmation, straight to slots

    /// The case that started this: a confident reminder must not ask permission,
    /// must keep the name it was given, and must ask for the time.
    func testConfidentReminderSkipsConfirmationAndCollectsSlots() async throws {
        let engine = makeEngine(confidence: 0.95)
        let response = await engine.handle(keywordRouted)

        guard case .prompt(let intent, let question, let filled) = response else {
            return XCTFail("expected a slot prompt, got \(response)")
        }
        XCTAssertEqual(intent, reminder)
        XCTAssertEqual(filled["name"], "go to the airport",
                       "the name is in the opening utterance — asking for it again is the bug")
        XCTAssertNil(filled["date_time"], "no time was given")
        XCTAssertEqual(question, askDateTime,
                       "the outstanding slot is the time, and the prompt is the pack's")
    }

    /// The other phrasing, through the carrier the pack has always shipped.
    func testPackCarriersHandleTheRemindMePhrasing() async throws {
        let engine = makeEngine(confidence: 0.95)
        let response = await engine.handle(classifierRouted)

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
        let engine = makeEngine(confidence: 0.80, gate: Self.testBand)
        let response = await engine.handle(classifierRouted)

        guard case .confirm(let intent, _, let question, _) = response else {
            return XCTFail("expected a confirmation, got \(response)")
        }
        XCTAssertEqual(intent, reminder)
        XCTAssertEqual(question, confirmPrompt)
    }

    /// VIK-021's actual damage. "Yes" used to fulfil with `parameters: [:]` —
    /// a reminder with no name and no time, reported as success.
    func testYesContinuesSlotFillingInsteadOfFulfillingEmpty() async throws {
        let engine = makeEngine(confidence: 0.80, gate: Self.testBand)

        let confirm = await engine.handle(classifierRouted)
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
        XCTAssertEqual(question, askDateTime)
    }

    /// The whole flow, as a user would walk it.
    func testAmbiguousReminderCompletesEndToEnd() async throws {
        let engine = makeEngine(confidence: 0.80, gate: Self.testBand)

        _ = await engine.handle(classifierRouted)
        _ = await engine.handle("yes")
        let done = await engine.handle("tomorrow at 5pm")

        guard case .fulfill(let intent, let action, let parameters, let message, _, _, _) = done else {
            return XCTFail("expected fulfilment, got \(done)")
        }
        XCTAssertEqual(intent, reminder)
        XCTAssertEqual(action, self.action, "the action is the pack's, not a literal")
        XCTAssertEqual(parameters["name"], "go to the airport")
        XCTAssertNotNil(parameters["date_time"], "the time answer must be stored")
        XCTAssertEqual(message, fulfilment)

        let collecting = await engine.isCollecting
        XCTAssertFalse(collecting, "the flow is finished")
    }

    // MARK: Declining

    func testNoCancelsAndClearsTheFlow() async throws {
        let engine = makeEngine(confidence: 0.80, gate: Self.testBand)

        _ = await engine.handle(classifierRouted)
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
            let engine = makeEngine(confidence: 0.80, gate: Self.testBand)
            _ = await engine.handle(classifierRouted)
            let response = await engine.handle(word)

            guard case .fulfill(_, _, _, let message, _, _, _) = response else {
                return XCTFail("'\(word)' did not decline — got \(response)")
            }
            XCTAssertEqual(message, pack.responses["sys.confirm.cancelled"], word)
        }
    }

    func testEveryAcceptWordInThePackActuallyAccepts() async throws {
        for word in pack.lexicon.affirmative {
            let engine = makeEngine(confidence: 0.80, gate: Self.testBand)
            _ = await engine.handle(classifierRouted)
            let response = await engine.handle(word)

            guard case .prompt = response else {
                return XCTFail("'\(word)' did not accept — got \(response)")
            }
        }
    }
    func testIntentSurvivesThroughInitialClassificationFollowUpConfirmationAndFulfilled() async throws {
        let engine = makeEngine(confidence: 0.80, gate: Self.testBand)
        
        // 1. Initial classification -> Returns confirm
        let confirmResponse = await engine.handle(classifierRouted)
        guard case .confirm(let intent1, _, _, let filled1) = confirmResponse else {
            return XCTFail("Expected confirm, got \(confirmResponse)")
        }
        XCTAssertEqual(intent1, reminder)
        XCTAssertEqual(filled1["name"], "go to the airport")
        
        // 2. Affirmative -> Returns prompt (followUp) for slots
        let promptResponse = await engine.handle("yes")
        guard case .prompt(let intent2, _, let filled2) = promptResponse else {
            return XCTFail("Expected prompt, got \(promptResponse)")
        }
        XCTAssertEqual(intent2, reminder)
        XCTAssertEqual(filled2["name"], "go to the airport")
        
        // 3. Fulfill the slots -> Returns fulfill
        let fulfillResponse = await engine.handle("tomorrow at 5pm")
        guard case .fulfill(let intent3, _, let params, _, _, _, _) = fulfillResponse else {
            return XCTFail("Expected fulfill, got \(fulfillResponse)")
        }
        XCTAssertEqual(intent3, reminder)
        XCTAssertEqual(params["name"], "go to the airport")
        XCTAssertNotNil(params["date_time"])
    }

    func testResetSessionDoesNotInheritPreviousIntentOrSlots() async throws {
        let engine = makeEngine(confidence: 0.80, gate: Self.testBand)
        
        // Start a session for reminder
        let confirmTurn = await engine.handle(classifierRouted)
        guard case .confirm = confirmTurn else {
            return XCTFail("Expected confirm, got \(confirmTurn)")
        }
        
        // Reset the engine
        await engine.reset()
        
        // Send "yes". If it didn't reset, this would be interpreted as an affirmative answer to the confirmation, returning .prompt.
        // Since it reset, "yes" is treated as a brand new utterance. The stub classifier returns `reminder`, which needs confirmation, so we expect .confirm.
        let turnAfterReset = await engine.handle("yes")
        guard case .confirm = turnAfterReset else {
            return XCTFail("Expected confirm after reset since 'yes' is treated as a new utterance, got \(turnAfterReset)")
        }
    }
}
