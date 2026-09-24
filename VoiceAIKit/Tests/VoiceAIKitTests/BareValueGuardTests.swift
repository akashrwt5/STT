// BareValueGuardTests.swift
// VoiceAIKitTests
//
// A value on its own is not a request.
//
// "outdoors" names a memory and "at 9" is a time, and when no flow is open
// neither asks for anything: a stray word must not switch a program, and a bare
// time must not open a reminder (the classifier reads "at 9" as reminders.add at
// 1.00 on the word `at` alone — the `9` never reaches it). Both fall back. The
// same values still work where they ARE answers — inside the slot prompt — and
// inside a sentence that carries its own request.
//
// Mirrors `engine.py::_apply_bare_value_guard` / `_is_bare_datetime`.

import XCTest
@testable import VoiceAIKit

private actor FixedClassifier: IntentClassifying {
    private let label: String
    init(label: String) { self.label = label }

    func classifyAsync(_ text: String) async -> ClassificationResult {
        ClassificationResult(
            label: label,
            confidence: 0.99,
            semanticRescue: false,
            breakdown: ClassificationBreakdown(
                winningStage: 2,
                stage2: ClassificationBreakdown.StageResult(
                    stage: 2, intent: label, confidence: 0.99),
                stage3: nil))
    }

    func warmUp() async {}
    func loadStage3() async {}
    func releaseStage3() async {}
}

final class BareValueGuardTests: XCTestCase {

    private var pack: ResolvedPack!
    private var schema: NLUSchema!
    private var reminder: String!
    private var memory: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pack = try PackTestSupport.loadPack()
        schema = try PackEngineFactory.schema(from: pack)
        reminder = try PackTestSupport.intent(requiringSlots: ["name", "date-time"], in: pack)
        memory = try PackTestSupport.intent(requiringSlots: ["memory_name"], in: pack)
    }

    /// The pack's own guards plus the date-time entry, which packs from
    /// v1.0.63 carry (`platform.yaml -> bare_value_guard`). Added here only when
    /// the seeded pack predates it, so the test does not depend on the seed.
    private var guards: [PackGuards.BareValueGuard] {
        var g = pack.guards.bareValue
        let dateEntity = reminderDateEntity
        if !g.contains(where: { $0.intent == reminder && $0.entity == dateEntity }) {
            g.append(PackGuards.BareValueGuard(intent: reminder, entity: dateEntity, redirect: nil))
        }
        return g
    }

    private var reminderDateEntity: String {
        schema.intents[reminder]?.slots.first { $0.name == "date-time" }?.entity ?? "sys.date-time"
    }

    private func makeEngine(routingTo intent: String) -> NLUEngine {
        NLUEngine(
            schema: schema,
            classifier: FixedClassifier(label: intent),
            entities: PackSlotResolver(pack: pack),
            uncertain: [],
            noIdioms: [],
            carriers: pack.lexicon.carriers,
            interruptThreshold: pack.policies.thresholds.interrupt,
            maxSlotAttempts: pack.policies.limits.maxSlotAttempts,
            oovReject: nil,
            oovBypass: nil,
            leadingConnectors: pack.lexicon.leadingConnectors,
            confirmationGates: PackEngineFactory.confirmationGates(from: pack),
            bareValueGuards: guards)
    }

    private func isFallback(_ r: NLUResponse) -> Bool {
        if case .fallback = r { return true }
        return false
    }

    // MARK: - Date-time

    func testABareTimeDoesNotOpenAReminder() async {
        for text in ["at 9", "at 5", "tomorrow", "tomorrow at 9"] {
            let r = await makeEngine(routingTo: reminder).handle(text)
            XCTAssertTrue(isFallback(r), "'\(text)' opened a flow on a time alone: \(r)")
        }
    }

    func testATimeInsideARequestStillOpensTheReminder() async {
        for text in ["remind me at 9", "set a reminder for 5 pm", "remind me tomorrow", "meeting at 5"] {
            let r = await makeEngine(routingTo: reminder).handle(text)
            XCTAssertFalse(isFallback(r), "'\(text)' carries its own request and must not be guarded: \(r)")
        }
    }

    /// The guard is for a NEW intent only. Asked "when?", "at 9" is the answer.
    func testABareTimeStillAnswersTheTimePrompt() async {
        let engine = makeEngine(routingTo: reminder)
        let first = await engine.handle("remind me to call mom")
        guard case .prompt(_, _, let filled) = first else {
            return XCTFail("expected the date-time prompt, got \(first)")
        }
        XCTAssertNil(filled["date-time"])
        let answer = await engine.handle("at 9")
        guard case .fulfill(_, _, let params, _, _, _, _, _) = answer else {
            return XCTFail("'at 9' did not answer the time prompt: \(answer)")
        }
        XCTAssertNotNil(params["date-time"])
        XCTAssertEqual(params["name"], "call mom")
    }

    // MARK: - Memory, unchanged

    func testABareMemoryNameStillFallsBack() async {
        let r = await makeEngine(routingTo: memory).handle("outdoors")
        XCTAssertTrue(isFallback(r), "a bare memory name switched the program: \(r)")
    }

    func testAnExplicitSwitchStillWorks() async {
        let r = await makeEngine(routingTo: memory).handle("switch to outdoors")
        XCTAssertFalse(isFallback(r), "'switch to outdoors' must still switch: \(r)")
    }
}
