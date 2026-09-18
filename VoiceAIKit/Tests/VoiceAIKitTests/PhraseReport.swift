// PhraseReport.swift
// VoiceAIKitTests
//
// A DIAGNOSTIC HARNESS, NOT A GATE.
//
// Runs a corpus of labelled phrases through the real pack and prints what the
// engine does with each one. It asserts NOTHING — so it can never fail, and it
// must never be read as proof that anything works. `ReferenceParityTests` and
// `KeywordArbitrationTests` are the gates; this is the thing you run when you
// want to SEE the behaviour across thousands of phrases at once.
//
// Named `PhraseReport`, not `PhraseReportTests`, for that reason.
//
// ── Running it ───────────────────────────────────────────────────────────────
//
// EDIT ONE LINE — `PhraseScope.selected`, a few lines below. Then run the test.
// That is the whole interface; nothing needs to be configured anywhere else.
//
//     .commands                       every Cmd.* label     ← the default
//     .help                           every Help_* label
//     .other                          reminders.* and the fallback
//     .all                            everything
//     .intent("Cmd.VolumeIncrease")   one label, by exact name
//
// `PHRASE_SCOPE` in the environment overrides that line when it is set, so a
// command-line or CI run can pick a scope without editing the file. Unset — the
// normal case in Xcode — means `selected` wins.
//
// COST. The default scope is ~2.4k phrases and this runs TWO inferences each,
// so expect it to take a while and to run on every full-suite pass. It asserts
// nothing, so it can only cost time, never a red build. If that time becomes a
// problem the honest fix is to set `selected` to one label, not to make the
// harness quieter about what it is doing.
//
// ── The fixture ──────────────────────────────────────────────────────────────
//
// `Fixtures/help_intent_phrases.json`, a Dialogflow-shaped export:
//
//     [ { "queryText": "louder", "displayName": "Cmd.VolumeIncrease",
//         "languageCode": "en", "timeStamp": "…" }, … ]
//
// `displayName` is the EXPECTED intent. It is reported as a match marker, never
// asserted — this file's whole point is to show you the answer, not to judge it.

import XCTest
@testable import VoiceAIKit

// MARK: - Scope

/// Which slice of the corpus to run.
enum PhraseScope: Equatable {
    case all
    /// Every `Cmd.*` label.
    case commands
    /// Every `Help_*` label.
    case help
    /// Everything that is neither — `reminders.*` and the fallback. There is no
    /// prefix they share, so this is "the remainder" rather than a family.
    case other
    /// One label, by exact name.
    case intent(String)

    // ═══════════════════════════════════════════════════════════════════════
    //  ▼▼▼  THE ONE LINE TO EDIT  ▼▼▼
    //
    //  .commands  |  .help  |  .other  |  .all  |  .intent("Cmd.VolumeIncrease")
    //
    static let selected: PhraseScope = .other
    //
    //  ▲▲▲                            ▲▲▲
    // ═══════════════════════════════════════════════════════════════════════

    /// Where an unusable choice lands — an empty `PHRASE_SCOPE`, or a name no
    /// row in the corpus carries.
    static let fallbackDefault = PhraseScope.commands

    /// Parses `PHRASE_SCOPE` when it is set. Nil when unset, which is the normal
    /// case — the caller then uses `selected`.
    static func fromEnvironment(_ raw: String?) -> PhraseScope? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "cmd", "cmd.*", "commands": return .commands
        case "help", "help_*":               return .help
        case "other", "rest":                return .other
        case "all":                          return .all
        default:                             return .intent(raw.trimmingCharacters(in: .whitespaces))
        }
    }

    func admits(_ label: String) -> Bool {
        switch self {
        case .all:               return true
        case .commands:          return label.hasPrefix("Cmd.")
        case .help:              return label.hasPrefix("Help_")
        case .other:             return !label.hasPrefix("Cmd.") && !label.hasPrefix("Help_")
        case .intent(let name):  return label == name
        }
    }

    var describedName: String {
        switch self {
        case .all:              return "all"
        case .commands:         return "Cmd.*"
        case .help:             return "Help_*"
        case .other:            return "other (reminders.*, fallback)"
        case .intent(let name): return name
        }
    }
}

// MARK: - Fixture

private struct PhraseRow: Decodable {
    let queryText: String
    let displayName: String
}

/// One phrase to run, with how many times the corpus carries it.
private struct Probe {
    let text: String
    let expected: String
    let occurrences: Int
}

/// What happened to it.
private struct Outcome {
    let probe: Probe
    /// The MODEL's own reading, before any rule or guard touched it.
    let modelIntent: String
    let modelConfidence: Double
    /// nil when no keyword rule fired.
    let arbitration: String
    /// What the engine finally reported, and which shape it reported it in.
    let finalIntent: String
    let kind: String
    let finalConfidence: Double?
    /// Non-zero features the head scored on. A one-feature vector saturates the
    /// softmax, so a high confidence next to `features 1` means the opposite of
    /// what it looks like.
    let features: Int
    /// Share of tokens the featurizer cannot represent. Read together with
    /// `features`: high `oov` + low `features` is the degenerate case.
    let oov: Double
    /// Which keyword rule claimed the turn, "-" when none did. Without it a
    /// `ruleOnly` row shows the model's label and the final label and hides the
    /// rule's — the one that actually decided.
    let ruleIntent: String

    var matchesExpected: Bool { finalIntent == probe.expected }
}

// MARK: - Report

final class PhraseReport: XCTestCase {

    /// Labels that are NOT classifier labels. The model cannot emit these — they
    /// are dialogue acts, produced by resolving a confirmation, so running them
    /// as fresh utterances measures nothing. Reported and skipped rather than
    /// silently included in a match rate they would drag down for no reason.
    private static let dialogueActLabels: Set<String> = [
        "Cmd.SendMessage - yes", "Cmd.SendMessage - no",
    ]

    func testReportPhraseOutcomes() async throws {
        // `selected` is the interface; the environment is an override for a
        // command-line run. No skip — the harness runs whenever the suite does,
        // which is what "default to Cmd.*" has to mean for it to be useful.
        let fromEnv = PhraseScope.fromEnvironment(ProcessInfo.processInfo.environment["PHRASE_SCOPE"])
        let requested = fromEnv ?? PhraseScope.selected
        let chosenVia = fromEnv == nil ? "PhraseScope.selected" : "PHRASE_SCOPE"

        let pack = try PackTestSupport.loadPack()
        let schema = try PackEngineFactory.schema(from: pack)
        let engine = try PackEngineFactory.makeEngine(pack: pack)
        // A second adapter, deliberately. The engine owns one but does not expose
        // it, and `NLUResponse` carries `breakdown` only on `.fulfill`/`.fallback`
        // — so a `.prompt` or `.confirm` turn would report no model verdict at
        // all. Two inferences per phrase buys the column that makes this report
        // worth reading; at ~1 ms on `.cpuOnly` that is a few seconds per
        // thousand phrases.
        let classifier = try PackClassifierAdapter(pack: pack)

        let all = try Self.loadFixture()
        let scope = Self.resolve(requested, against: all)

        var byLabel: [String: [Probe]] = [:]
        for probe in Self.probes(in: all, matching: scope) {
            byLabel[probe.expected, default: []].append(probe)
        }

        let skipped = byLabel.keys.filter { Self.dialogueActLabels.contains($0) }.sorted()
        for label in skipped { byLabel.removeValue(forKey: label) }

        let totalProbes = byLabel.values.reduce(0) { $0 + $1.count }
        let totalRows = byLabel.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.occurrences } }

        print("""

            ════════════════════════════════════════════════════════════════════
             PHRASE REPORT — no assertions, nothing here can fail
             pack   \(pack.manifest.bundleID) [\(pack.language)], \(pack.classifier.variant.rawValue) head
             scope  \(scope.describedName)   via \(chosenVia)\(scope == requested ? "" : "   ⚠︎ requested \(requested.describedName) — no row in the corpus carries it, fell back")
             labels \(byLabel.count)
             probes \(totalProbes) distinct, \(totalRows) rows in the corpus
             bars   fire \(pack.policies.thresholds.confidence), \
            agreement \(pack.policies.thresholds.agreement.map { String($0) } ?? "off")
            ════════════════════════════════════════════════════════════════════
            """)
        if !skipped.isEmpty {
            print("""
             skipped \(skipped.joined(separator: ", ")) — dialogue-act labels the \
            classifier cannot emit; they are reachable only by answering a live confirmation.
            """)
        }

        var tsv = "label\tphrase\toccurrences\tmodel\tmodel_confidence\tarbitration\trule_intent\tfeatures\toov\tfinal\tkind\tfinal_confidence\tmatches\n"
        var grandMatched = 0, grandTotal = 0
        var grandKinds: [String: Int] = [:]

        for label in byLabel.keys.sorted() {
            let probes = byLabel[label]!.sorted { $0.text.lowercased() < $1.text.lowercased() }
            var outcomes: [Outcome] = []

            Self.printSectionHeader(label: label, probes: probes)

            for probe in probes {
                // PRINT THE PHRASE FIRST, BEFORE RUNNING IT.
                //
                // `NLUEngine` emits its own `decide model=… arbitration=… final=…`
                // line per turn, and that line carries NO transcript on purpose —
                // production logs must not record what the user said. So when this
                // harness batched its table until the end of a label, the console
                // filled with hundreds of phrase-less `decide` lines first and the
                // table after, and nothing said which line belonged to which
                // phrase. Printing the phrase first means every log line the engine
                // produces lands underneath the phrase that caused it.
                print("  ▸ \(probe.text)\(probe.occurrences > 1 ? "   ×\(probe.occurrences)" : "")")

                // MANDATORY. `handle` runs a CONVERSATION: a phrase that opens a
                // slot flow leaves `pendingIntent` armed, and the next phrase is
                // then read as an ANSWER to it rather than as a new utterance.
                // Without this every phrase after the first "add reminder" would
                // be reported wrongly, and nothing would say so.
                await engine.reset()

                let verdict = await classifier.classifyAsync(probe.text)
                // Observability, read from the same adapter and therefore the same
                // vocabulary the verdict came from. Neither call touches the engine.
                let features = await classifier.featureCount(probe.text)
                let oov = await classifier.oovRatio(probe.text)
                let ruleIntent = await classifier.firstKeywordIntent(probe.text)
                let response = await engine.handle(probe.text)
                let outcome = Self.outcome(probe: probe, verdict: verdict, response: response,
                                           features: features, oov: oov, ruleIntent: ruleIntent)
                outcomes.append(outcome)
                print("    " + Self.line(for: outcome))
            }

            Self.printSectionFooter(label: label, outcomes: outcomes)

            for o in outcomes {
                tsv += "\(label)\t\(o.probe.text)\t\(o.probe.occurrences)\t\(o.modelIntent)\t"
                tsv += String(format: "%.4f", o.modelConfidence) + "\t\(o.arbitration)\t"
                tsv += "\(o.ruleIntent)\t\(o.features)\t" + String(format: "%.2f", o.oov) + "\t"
                tsv += "\(o.finalIntent)\t\(o.kind)\t"
                tsv += (o.finalConfidence.map { String(format: "%.4f", $0) } ?? "-")
                tsv += "\t\(o.matchesExpected ? "yes" : "no")\n"
                grandKinds[o.kind, default: 0] += 1
                grandTotal += 1
                if o.matchesExpected { grandMatched += 1 }
            }
        }

        let pct = grandTotal > 0 ? 100.0 * Double(grandMatched) / Double(grandTotal) : 0
        print("""

            ════════════════════════════════════════════════════════════════════
             TOTAL  \(grandTotal) distinct phrases across \(byLabel.count) labels
             kinds  \(grandKinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "   "))
             final intent == corpus label: \(grandMatched)  (\(String(format: "%.1f", pct))%)

             NOT AN ACCURACY FIGURE. The corpus label is one person's reading of
             the phrase, the pack is another, and a PROMPT or CONFIRM turn has not
             finished deciding yet. Read the rows, not this number.
            ════════════════════════════════════════════════════════════════════
            """)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrase-report-\(Self.slug(scope.describedName)).tsv")
        try tsv.write(to: out, atomically: true, encoding: .utf8)
        print("\n TSV → \(out.path)\n   open it with: open \(out.path)\n")

        _ = schema  // loaded for the header; kept so a future assertion has it to hand
    }

    // MARK: - Pieces

    private static func loadFixture() throws -> [PhraseRow] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/help_intent_phrases.json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("no corpus at Fixtures/help_intent_phrases.json")
        }
        return try JSONDecoder().decode([PhraseRow].self, from: data)
    }

    /// Falls back to the default scope when the requested one matches no row, so
    /// a typo in `PHRASE_SCOPE` reports zero labels loudly instead of quietly.
    private static func resolve(_ requested: PhraseScope, against rows: [PhraseRow]) -> PhraseScope {
        rows.contains { requested.admits($0.displayName) } ? requested : .fallbackDefault
    }

    /// Distinct phrases, with how many rows each one stands for. The corpus
    /// carries 5411 rows and 1842 distinct texts; printing the same phrase nine
    /// times tells you nothing the count does not.
    private static func probes(in rows: [PhraseRow], matching scope: PhraseScope) -> [Probe] {
        var counts: [String: (text: String, label: String, n: Int)] = [:]
        for row in rows where scope.admits(row.displayName) {
            let text = row.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let key = text.lowercased() + "\u{1}" + row.displayName
            counts[key, default: (text, row.displayName, 0)].n += 1
        }
        return counts.values.map { Probe(text: $0.text, expected: $0.label, occurrences: $0.n) }
    }

    private static func outcome(probe: Probe,
                                verdict: ClassificationResult,
                                response: NLUResponse,
                                features: Int,
                                oov: Double,
                                ruleIntent: String?) -> Outcome {
        let kind: String
        let finalIntent: String
        var finalConfidence: Double?
        switch response {
        case .fulfill(let i, _, _, _, let c, _, _, _): kind = "FULFILL";  finalIntent = i; finalConfidence = c
        case .fallback(let i, let c, _):            kind = "FALLBACK"; finalIntent = i; finalConfidence = c
        case .prompt(let i, _, _):                  kind = "PROMPT";   finalIntent = i
        case .confirm(let i, _, _, _):              kind = "CONFIRM";  finalIntent = i
        case .interrupted(let i, _):                kind = "INTERRUPT"; finalIntent = i
        }
        return Outcome(
            probe: probe,
            // `breakdown.stage2` is the model's own reading, filled by the adapter
            // even when a keyword rule decided the label.
            modelIntent: verdict.breakdown.stage2?.intent ?? verdict.label,
            modelConfidence: verdict.breakdown.stage2?.confidence ?? verdict.confidence,
            arbitration: verdict.arbitration?.rawValue ?? "-",
            finalIntent: finalIntent,
            kind: kind,
            finalConfidence: finalConfidence,
            features: features,
            oov: oov,
            ruleIntent: ruleIntent ?? "-")
    }

    private static func printSectionHeader(label: String, probes: [Probe]) {
        let rows = probes.reduce(0) { $0 + $1.occurrences }
        print("""

            ══ \(label) — \(probes.count) distinct phrase(s), \(rows) row(s) ══
            """)
    }

    /// One phrase's result, deliberately under ~90 characters so the Xcode
    /// console does not wrap it and split a row across two visual lines.
    private static func line(for o: Outcome) -> String {
        let model = "\(o.modelIntent) " + String(format: "%.3f", o.modelConfidence)
        let final = o.finalConfidence.map { " " + String(format: "%.3f", $0) } ?? ""
        let shape = "f\(o.features)/o" + String(format: "%.2f", o.oov)
        let rule = o.ruleIntent == "-" ? "" : " · rule \(o.ruleIntent)"
        return "\(o.matchesExpected ? "✓" : "✗")  model \(model) · \(o.arbitration)\(rule) · \(shape)"
             + "  →  \(o.finalIntent)\(final) · \(o.kind)"
    }

    private static func printSectionFooter(label: String, outcomes: [Outcome]) {
        var kinds: [String: Int] = [:]
        for o in outcomes { kinds[o.kind, default: 0] += 1 }
        let matched = outcomes.filter(\.matchesExpected).count
        let pct = outcomes.isEmpty ? 0 : 100.0 * Double(matched) / Double(outcomes.count)
        print("   └─ " + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "  ")
              + "  │  final == \(label): \(matched)/\(outcomes.count) (\(String(format: "%.1f", pct))%)")
    }

    private static func slug(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}
