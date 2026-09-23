// OpenSlotTitleTaggerTests.swift
// VoiceAIKitTests
//
// Where an OPEN free-text slot's title comes from once the pack ships a BIO
// title tagger. One rule, used for the opening utterance AND for the answer to
// the slot's own prompt:
//
//     tagger  ->  deriveTopic  ->  (answer only) the raw text
//
// Mirrors `engine.py::_fill_open_topics` (tagger, then `_derive_topic`). The
// raw-text tail applies only to an answer: the user was asked for the title and
// said something, so something is stored.
//
// Most tests inject a scripted extractor, so they pin the ORDER without
// depending on what the model happens to say. The last group runs the real
// `PackSlotTagger` over the fixture weights end to end.

import XCTest
@testable import VoiceAIKit

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

/// Answers from a fixed table; nil for anything else, which is what a real
/// tagger returns when it sees no subject.
private struct ScriptedTitles: OpenSlotTitleExtracting {
    let table: [String: String]
    func title(of text: String) -> String? { table[text] }
}

final class OpenSlotTitleTaggerTests: XCTestCase {

    private var pack: ResolvedPack!
    private var schema: NLUSchema!
    private var reminder: String!

    /// A `set a reminder` opening carries no title of its own (a carrier strips it
    /// to nothing), so the engine's first move is to ask for one.
    private let openReminder = "set a reminder"

    /// The pattern `language_packs/en/platform.yaml -> lexicon.topic_anchors`
    /// ships. Written out here because pack v1.0.61 predates the key; once the
    /// seed pack carries it, `pack.lexicon.topicAnchors` is the same list.
    private let englishTopicAnchor =
        #"\b(?:(?:set(?:\s+up)?|make|create|add)\s+(?:an?\s+)?(?:reminder|remindr|alarm)|remind\s+me)\s+(?:to|about|that|for)\s+"#

    override func setUpWithError() throws {
        try super.setUpWithError()
        pack = try PackTestSupport.loadPack()
        schema = try PackEngineFactory.schema(from: pack)
        reminder = try PackTestSupport.intent(requiringSlots: ["name", "date-time"], in: pack)
    }

    private func makeEngine(titles: (any OpenSlotTitleExtracting)?,
                            topicAnchors: [String] = []) -> NLUEngine {
        NLUEngine(
            schema: schema,
            classifier: FixedClassifier(label: reminder),
            entities: PackSlotResolver(pack: pack),
            uncertain: [],
            noIdioms: [],
            carriers: pack.lexicon.carriers,
            interruptThreshold: pack.policies.thresholds.interrupt,
            maxSlotAttempts: pack.policies.limits.maxSlotAttempts,
            oovReject: pack.policies.thresholds.oovReject,
            oovBypass: pack.policies.thresholds.oovBypass,
            leadingConnectors: pack.lexicon.leadingConnectors,
            topicAnchors: topicAnchors,
            titleExtractor: titles,
            confirmationGates: PackEngineFactory.confirmationGates(from: pack))
    }

    /// The name the opening utterance stores, whether or not the flow completes.
    private func openingName(_ engine: NLUEngine, _ text: String,
                             file: StaticString = #filePath, line: UInt = #line) async -> String? {
        let result = await engine.handle(text)
        switch result {
        case .prompt(_, _, let filled):
            return filled["name"]
        case .fulfill(_, _, let params, _, _, _, _, _):
            return params["name"]
        default:
            XCTFail("'\(text)' neither prompted nor fulfilled — got \(result)", file: file, line: line)
            return nil
        }
    }

    /// The name stored when `answer` replies to the name prompt.
    private func answeredName(_ engine: NLUEngine, _ answer: String,
                              file: StaticString = #filePath, line: UInt = #line) async -> String? {
        let first = await engine.handle(openReminder)
        guard case .prompt = first else {
            XCTFail("'\(openReminder)' did not open a prompt — got \(first)", file: file, line: line)
            return nil
        }
        return await openingName(engine, answer, file: file, line: line)
    }

    // MARK: - Opening utterance

    func testOpeningTakesTheTaggersTitleOverDeriveTopic() async {
        let text = "remind me at 9pm for dinner"
        let engine = makeEngine(titles: ScriptedTitles(table: [text: "dinner party"]))
        let name = await openingName(engine, text)
        XCTAssertEqual(name, "dinner party", "the tagger's span must win when it finds one")
    }

    func testOpeningFallsBackToDeriveTopicWhenTheTaggerSeesNoSubject() async {
        let engine = makeEngine(titles: ScriptedTitles(table: [:]))
        let name = await openingName(engine, "remind me to buy milk")
        XCTAssertEqual(name, "buy milk", "a nil tagger answer must fall through to deriveTopic")
    }

    func testWithNoTaggerTheOpeningIsExactlyDeriveTopic() async {
        let tagged = makeEngine(titles: ScriptedTitles(table: [:]))
        let untagged = makeEngine(titles: nil)
        let text = "remind me to call mom"
        let a = await openingName(tagged, text)
        let b = await openingName(untagged, text)
        XCTAssertEqual(a, b)
    }

    // MARK: - Answer to the prompt

    func testAnAnswerTakesTheTaggersTitle() async {
        let answer = "it's to pick up the kids"
        let engine = makeEngine(titles: ScriptedTitles(table: [answer: "pick up the kids"]))
        let name = await answeredName(engine, answer)
        XCTAssertEqual(name, "pick up the kids")
    }

    func testAnAnswerFallsBackToDeriveTopic() async {
        // The real tagger returns nil for this; deriveTopic drops the connector.
        let engine = makeEngine(titles: ScriptedTitles(table: [:]))
        let name = await answeredName(engine, "about the dentist")
        XCTAssertEqual(name, "the dentist")
    }

    func testABareNounAnswerIsKept() async {
        // The real tagger returns nil for a bare noun — the most common answer
        // shape. deriveTopic keeps it; it must not be lost.
        let engine = makeEngine(titles: ScriptedTitles(table: [:]))
        let name = await answeredName(engine, "milk")
        XCTAssertEqual(name, "milk")
    }

    func testAnAnswerWithNoSubjectAtAllKeepsTheRawText() async {
        // Neither the tagger nor deriveTopic finds a subject (the date parser
        // strips the whole thing), so the raw answer is the last resort.
        let answer = "tomorrow at 5"
        let engine = makeEngine(titles: ScriptedTitles(table: [:]))
        let name = await answeredName(engine, answer)
        XCTAssertEqual(name, answer)
    }

    /// VIK-039's invariant, with a tagger in the loop: the same sentence names the
    /// reminder the same way wherever it is said.
    func testOpeningAndAnswerAgreeWithATagger() async {
        let sentence = "remind me to call mom at 9am"
        let titles = ScriptedTitles(table: [sentence: "call mom"])
        let opening = await openingName(makeEngine(titles: titles), sentence)
        let answer = await answeredName(makeEngine(titles: titles), sentence)
        XCTAssertEqual(opening, "call mom")
        XCTAssertEqual(opening, answer)
    }

    // MARK: - Topic anchors

    func testATopicAnchorCutsFillerBeforeTheRequest() async {
        let text = "ok so basically set up a reminder for the meeting"
        let without = await openingName(makeEngine(titles: nil), text)
        let with = await openingName(makeEngine(titles: nil, topicAnchors: [englishTopicAnchor]), text)
        XCTAssertEqual(with, "the meeting")
        XCTAssertNotEqual(without, with, "the anchor changed nothing — is it being applied?")
    }

    // MARK: - The real tagger, end to end

    private func realTagger() throws -> PackSlotTagger {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/slot_tagger_weights_en.json")
        return try PackSlotTagger(contentsOf: url)
    }

    /// Titles the Python reference produces for the same weights
    /// (`JsonSlotTagger.title`), measured, not assumed.
    func testTheRealTaggerNamesTheReminderLikePython() async throws {
        let engine = makeEngine(titles: try realTagger())
        let cases: [(String, String)] = [
            ("please remind me to take my medicine tomorrow at 5 pm", "take my medicine"),
            ("remind me to go to airport at 4", "airport"),
            ("tomorrow morning remind me to water the plants", "water the plants"),
        ]
        for (text, expected) in cases {
            await engine.reset()
            let name = await openingName(engine, text)
            XCTAssertEqual(name, expected, "'\(text)'")
        }
    }
}
