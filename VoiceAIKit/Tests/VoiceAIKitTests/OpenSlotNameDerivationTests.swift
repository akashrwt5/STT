// OpenSlotNameDerivationTests.swift
// VoiceAIKitTests
//
// What an OPEN free-text slot stores when the user answers its prompt.
//
// The opening utterance has always run `deriveTopic` (via `fillOpenTopics`):
// carrier stripped, date/time stripped, leading connective stripped. The answer
// to the slot's own prompt did not — it took the raw text, and consulted the
// gazetteer first. So the same sentence produced two different names depending
// on where it was said, and a time the user mentioned stayed inside the name
// while also filling `date_time`.

import XCTest
@testable import VoiceAIKit

/// Answers with a fixed label. These tests are about derivation, not routing —
/// the classifier never decides anything here.
private actor FixedClassifier: IntentClassifying {
    private let label: String
    init(label: String) { self.label = label }

    func classifyAsync(_ text: String) async -> ClassificationResult {
        ClassificationResult(
            label: label,
            confidence: 0.95,
            semanticRescue: false,
            breakdown: ClassificationBreakdown(
                winningStage: 2,
                stage2: ClassificationBreakdown.StageResult(
                    stage: 2, intent: label, confidence: 0.95),
                stage3: nil))
    }

    func warmUp() async {}
    func loadStage3() async {}
    func releaseStage3() async {}
}


/// Answers a named utterance with a different verdict from the default. Needed
/// because `FixedClassifier` cannot express "this answer looks like some other
/// intent" — which is the whole situation the interrupt gate is about.
private actor ScriptedClassifier: IntentClassifying {
    struct Verdict: Sendable {
        let label: String
        let confidence: Double
    }

    private let fallback: Verdict
    private let script: [String: Verdict]

    init(fallback: Verdict, script: [String: Verdict]) {
        self.fallback = fallback
        self.script = script
    }

    func classifyAsync(_ text: String) async -> ClassificationResult {
        let v = script[text] ?? fallback
        return ClassificationResult(
            label: v.label,
            confidence: v.confidence,
            semanticRescue: false,
            breakdown: ClassificationBreakdown(
                winningStage: 2,
                stage2: ClassificationBreakdown.StageResult(
                    stage: 2, intent: v.label, confidence: v.confidence),
                stage3: nil))
    }

    func warmUp() async {}
    func loadStage3() async {}
    func releaseStage3() async {}
}

final class OpenSlotNameDerivationTests: XCTestCase {

    private var pack: ResolvedPack!
    private var schema: NLUSchema!
    /// Free-text name + a time — the flow with an open slot.
    private var reminder: String!
    /// A closed gazetteer slot, to prove it is untouched.
    private var memory: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pack = try PackTestSupport.loadPack()
        schema = PackEngineFactory.schema(from: pack)
        reminder = try PackTestSupport.intent(requiringSlots: ["name", "date_time"], in: pack)
        memory   = try PackTestSupport.intent(requiringSlots: ["memory_name"], in: pack)
    }

    /// Wired as `PackEngineFactory` wires one, classifier aside.
    private func makeEngine(routingTo intent: String) -> NLUEngine {
        NLUEngine(
            schema: schema,
            classifier: FixedClassifier(label: intent),
            entities: PackSlotResolver(pack: pack),
            uncertain: [],
            noIdioms: [],
            carriers: pack.lexicon.carriers,
            leadingConnectors: pack.lexicon.leadingConnectors,
            confirmationGates: PackEngineFactory.confirmationGates(from: pack))
    }


    /// An engine whose classifier answers `switchUtterance` with a DIFFERENT
    /// intent at a confidence far above the 0.75 interrupt threshold.
    private func makeEngine(routingTo intent: String,
                            butClassifying switchUtterance: String,
                            as other: String) -> NLUEngine {
        NLUEngine(
            schema: schema,
            classifier: ScriptedClassifier(
                fallback: .init(label: intent, confidence: 0.95),
                script: [switchUtterance: .init(label: other, confidence: 0.99)]),
            entities: PackSlotResolver(pack: pack),
            uncertain: [],
            noIdioms: [],
            carriers: pack.lexicon.carriers,
            leadingConnectors: pack.lexicon.leadingConnectors,
            confirmationGates: PackEngineFactory.confirmationGates(from: pack))
    }

    /// Any third intent, derived — never a literal label, so the taxonomy can move.
    private func someOtherIntent() throws -> String {
        try XCTUnwrap(schema.intents.keys.sorted().first { $0 != reminder && $0 != memory },
                      "pack has fewer than three intents with entries in the schema")
    }

    private func slotPrompt(_ intent: String, _ slot: String) -> String? {
        schema.intents[intent]?.slots.first { $0.name == slot }?.prompt
    }

    /// Hits the Stage-0 keyword rule and carries no name of its own, so the
    /// engine's first move is to ask for one.
    private let openReminder = "set a reminder"
    /// No keyword rule matches; the fixed classifier routes it.
    private let openMemory = "change memory"

    private func arriveAtPrompt(_ engine: NLUEngine,
                                opening: String,
                                intent: String,
                                slot: String,
                                file: StaticString = #filePath,
                                line: UInt = #line) async {
        let first = await engine.handle(opening)
        guard case .prompt(let got, let question, _) = first else {
            XCTFail("'\(opening)' did not open a slot prompt — got \(first)", file: file, line: line)
            return
        }
        XCTAssertEqual(got, intent, file: file, line: line)
        XCTAssertEqual(question, slotPrompt(intent, slot),
                       "expected the \(slot) prompt", file: file, line: line)
    }

    // MARK: - Carrier

    /// VIK-039. The user repeats the carrier when answering. It must not become the name.
    func testTheAnswerToThePromptHasItsCarrierStripped() async throws {
        let engine = makeEngine(routingTo: reminder)
        await arriveAtPrompt(engine, opening: openReminder, intent: reminder, slot: "name")

        let answer = await engine.handle("remind me to buy milk")
        guard case .prompt(_, let question, let filled) = answer else {
            return XCTFail("expected the next slot prompt, got \(answer)")
        }
        XCTAssertEqual(filled["name"], "buy milk",
                       "the carrier 'remind me to' must not survive into the name")
        XCTAssertEqual(question, slotPrompt(reminder, "date_time"))
    }

    // MARK: - Time goes to the time slot

    /// VIK-039. A time mentioned in the answer belongs in `date_time`, not in the name.
    ///
    /// Asserted as "the name does not contain the time" rather than an exact
    /// string: whether `strippingDateTime` also removes the preposition ("at")
    /// is the date parser's business, not this behaviour's.
    func testATimeInTheAnswerFillsTheDateSlotAndLeavesTheName() async throws {
        let engine = makeEngine(routingTo: reminder)
        await arriveAtPrompt(engine, opening: openReminder, intent: reminder, slot: "name")

        // "9am" is the bare-time form Fixtures/reference_expectations.json proves
        // resolves with timeExplicit=true, dayExplicit=false.
        let answer = await engine.handle("remind me to call mom at 9am")

        guard case .fulfill(_, _, let params, _, _, _, _) = answer else {
            return XCTFail("""
                both required slots should be filled from one utterance — got \(answer)
                """)
        }
        let name = try XCTUnwrap(params["name"], "name was not filled")
        XCTAssertFalse(name.lowercased().contains("9am"),
                       "the time leaked into the reminder name: '\(name)'")
        XCTAssertFalse(name.lowercased().contains("remind me"),
                       "the carrier leaked into the reminder name: '\(name)'")
        XCTAssertTrue(name.lowercased().contains("call mom"),
                      "the subject was lost from the name: '\(name)'")
        XCTAssertNotNil(params["date_time"],
                        "the time left the name but never reached the date_time slot")
    }

    // MARK: - The property that ties it together

    /// VIK-039. The same sentence must produce the same name whether it opens the
    /// conversation or answers the prompt. This is the whole point of the change,
    /// and it holds without this test knowing what `deriveTopic` returns.
    func testOpeningAndFollowUpDeriveTheSameName() async throws {
        let sentence = "remind me to call mom at 9am"

        // Opening: `fillOpenTopics` derives the name.
        let opening = makeEngine(routingTo: reminder)
        let openingResult = await opening.handle(sentence)
        guard case .fulfill(_, _, let openingParams, _, _, _, _) = openingResult else {
            return XCTFail("opening utterance did not complete the flow — got \(openingResult)")
        }

        // Follow-up: the same sentence answers the name prompt.
        let followUp = makeEngine(routingTo: reminder)
        await arriveAtPrompt(followUp, opening: openReminder, intent: reminder, slot: "name")
        let followUpResult = await followUp.handle(sentence)
        guard case .fulfill(_, _, let followUpParams, _, _, _, _) = followUpResult else {
            return XCTFail("follow-up answer did not complete the flow — got \(followUpResult)")
        }

        XCTAssertEqual(openingParams["name"], followUpParams["name"], """
            the same sentence produced different names depending on where it was said
            """)
    }

    // MARK: - Closed slots are untouched

    /// VIK-039. The gazetteer path is unchanged: a closed entity still resolves to its
    /// canonical value, and `deriveTopic` is not involved.
    func testAClosedSlotStillResolvesThroughTheGazetteer() async throws {
        let engine = makeEngine(routingTo: memory)
        await arriveAtPrompt(engine, opening: openMemory, intent: memory, slot: "memory_name")

        let answer = await engine.handle("restaurant")
        guard case .fulfill(let intent, _, let params, _, _, _, _) = answer else {
            return XCTFail("expected the memory flow to complete, got \(answer)")
        }
        XCTAssertEqual(intent, memory)
        XCTAssertEqual(params["memory_name"], "Restaurant",
                       "a closed entity must still return the gazetteer's canonical value")
    }

    /// VIK-040. "at 9" and "at nine" mean the same thing, so they must produce
    /// the same reminder name.
    ///
    /// They did not: `parse` normalises spelled-out numbers to digits before
    /// matching, `strippingDateTime` did not, and every one of its patterns was
    /// written in `\d`. So the time was read into `date_time` AND left in the
    /// topic — "remind me to call Mukesh at nine" was named "call Mukesh nine".
    func testASpelledOutTimeLeavesTheNameJustLikeADigitOne() async throws {
        let digitEngine = makeEngine(routingTo: reminder)
        let digits = await digitEngine.handle("remind me to call Mukesh at 9")
        guard case .fulfill(_, _, let digitParams, _, _, _, _) = digits else {
            return XCTFail("the digit form did not complete the flow — got \(digits)")
        }

        let wordEngine = makeEngine(routingTo: reminder)
        let words = await wordEngine.handle("remind me to call Mukesh at nine")
        guard case .fulfill(_, _, let wordParams, _, _, _, _) = words else {
            return XCTFail("the spelled-out form did not complete the flow — got \(words)")
        }

        let wordName = try XCTUnwrap(wordParams["name"])
        XCTAssertFalse(wordName.lowercased().contains("nine"),
                       "the spelled-out time stayed in the name: '\(wordName)'")
        XCTAssertEqual(digitParams["name"], wordParams["name"], """
            "at 9" and "at nine" produced different names
            """)
        XCTAssertNotNil(wordParams["date_time"],
                        "the spelled-out time never reached the date_time slot")
    }

    // MARK: - Interruption is gated on what the awaited slot can refuse

    /// VIK-038. The reminder's NAME slot is open free text: every utterance is a legal
    /// value, so the classifier has nothing to be right about and must not be
    /// consulted. This is the reported bug — "Need to go to walk" scored 0.994
    /// as an activity command and cancelled the reminder.
    func testTheOpenNameSlotNeverInterrupts() async throws {
        let switchLike = "increase volume"
        let engine = makeEngine(routingTo: reminder,
                                butClassifying: switchLike,
                                as: try someOtherIntent())
        await arriveAtPrompt(engine, opening: openReminder, intent: reminder, slot: "name")

        let answer = await engine.handle(switchLike)
        if case .interrupted = answer {
            return XCTFail("""
                an open free-text slot must never be interrupted — every utterance is a
                legal answer to it. Got \(answer)
                """)
        }
        guard case .prompt(_, let question, let filled) = answer else {
            return XCTFail("expected the next slot prompt, got \(answer)")
        }
        XCTAssertNotNil(filled["name"], "the answer should have filled the name")
        XCTAssertEqual(question, slotPrompt(reminder, "date_time"))
    }

    /// VIK-038. The reminder's DATE slot is judged by the date parser, not the classifier.
    /// A non-date answer re-prompts; it does not switch topic.
    func testTheDateSlotNeverInterrupts() async throws {
        let switchLike = "increase volume"
        let engine = makeEngine(routingTo: reminder,
                                butClassifying: switchLike,
                                as: try someOtherIntent())
        await arriveAtPrompt(engine, opening: openReminder, intent: reminder, slot: "name")

        let named = await engine.handle("buy milk")
        guard case .prompt(_, let dateQuestion, _) = named,
              dateQuestion == slotPrompt(reminder, "date_time") else {
            return XCTFail("expected the date_time prompt after naming, got \(named)")
        }

        let answer = await engine.handle(switchLike)
        if case .interrupted = answer {
            return XCTFail("a date-time slot must be judged by the parser, not the classifier")
        }
        guard case .prompt(_, let again, _) = answer else {
            return XCTFail("expected the date_time prompt again, got \(answer)")
        }
        XCTAssertEqual(again, slotPrompt(reminder, "date_time"))
    }

    /// VIK-038. The memory slot is a CLOSED gazetteer, so a miss is a fact — the one case
    /// where asking the classifier where the user went is honest. This must keep
    /// working; it is the half of the feature that was never broken.
    func testTheClosedMemorySlotStillInterrupts() async throws {
        let switchLike = "increase volume"
        let other = try someOtherIntent()
        let engine = makeEngine(routingTo: memory,
                                butClassifying: switchLike,
                                as: other)
        await arriveAtPrompt(engine, opening: openMemory, intent: memory, slot: "memory_name")

        let answer = await engine.handle(switchLike)
        guard case .interrupted(let cancelled, _) = answer else {
            return XCTFail("""
                a value the gazetteer cannot accept must still switch topic — got \(answer)
                """)
        }
        XCTAssertEqual(cancelled, memory)
    }
}
