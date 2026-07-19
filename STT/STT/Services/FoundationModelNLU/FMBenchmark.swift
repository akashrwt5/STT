// FMBenchmark.swift
// STT — FoundationModelNLU (evaluation sample; see docs/FM_SAMPLE_PLAN.md §8)
//
// Runs the bundled holdout set (Resources/FM/fm_holdout.csv — a copy of the
// IntentClassifier repo's semantic_holdout_2.csv: 341 utterances across all
// 59 in-scope intents) through FMIntentClassifierService and produces a
// shareable report.
//
// Success bars were fixed in the plan BEFORE any numbers existed:
//   - ≥ 89.4% overall (parity with the shipped cascade), OR
//   - ≥ 95% out-of-scope rejection (the fallback slot's actual job).
// Below both → the sample is archived with the report and the question is
// closed with data.
//
// Every report is stamped with OS build + device so results stay attributable
// when Apple revs the OS model (plan §10, risk 2).

import Foundation
import UIKit
#if canImport(FoundationModels)

@available(iOS 26.0, *)
struct FMBenchmarkReport: Sendable {
    struct Row: Sendable {
        let utterance: String
        let expected: String
        let predicted: String
        let latencyMS: Double
        let difficulty: String
        var correct: Bool { expected == predicted }
    }

    let rows: [Row]
    let osVersion: String
    let deviceModel: String
    let date: Date

    var total: Int { rows.count }
    var correct: Int { rows.filter(\.correct).count }
    var accuracy: Double { total == 0 ? 0 : Double(correct) / Double(total) }

    /// The cascade's holdout accuracy — the number FM has to beat for parity.
    static let cascadeBaseline = 0.894
    static let overallBar = 0.894
    static let oosRejectionBar = 0.95

    var latencyP50: Double { percentile(0.50) }
    var latencyP95: Double { percentile(0.95) }

    private func percentile(_ p: Double) -> Double {
        let sorted = rows.map(\.latencyMS).sorted()
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
        return sorted[idx]
    }

    /// Per-intent accuracy so weaknesses are localized, not averaged away.
    var perIntent: [(intent: String, correct: Int, total: Int)] {
        var buckets: [String: (Int, Int)] = [:]
        for row in rows {
            var b = buckets[row.expected] ?? (0, 0)
            b.1 += 1
            if row.correct { b.0 += 1 }
            buckets[row.expected] = b
        }
        return buckets.map { ($0.key, $0.value.0, $0.value.1) }
            .sorted { $0.0 < $1.0 }
    }

    /// Macro-F1 proxy: unweighted mean of per-intent recall. (True F1 needs
    /// per-class precision too; recall-macro is the number the training
    /// pipeline's per-class report centers on and is enough to spot collapse.)
    var macroRecall: Double {
        let per = perIntent
        guard !per.isEmpty else { return 0 }
        return per.map { Double($0.correct) / Double(max($0.total, 1)) }
            .reduce(0, +) / Double(per.count)
    }

    var summaryText: String {
        """
        FM Holdout Benchmark — \(ISO8601DateFormatter().string(from: date))
        Device: \(deviceModel) · OS: \(osVersion)
        Overall: \(correct)/\(total) = \(String(format: "%.1f%%", accuracy * 100)) \
        (cascade baseline \(String(format: "%.1f%%", Self.cascadeBaseline * 100)))
        Macro recall: \(String(format: "%.1f%%", macroRecall * 100))
        Latency: p50 \(String(format: "%.0f", latencyP50))ms · p95 \(String(format: "%.0f", latencyP95))ms
        Verdict vs. plan bars: overall \(accuracy >= Self.overallBar ? "PASS" : "below bar")
        """
    }

    /// Full CSV for export/share — one row per utterance plus the header block.
    var csvText: String {
        var out = "# \(summaryText.replacingOccurrences(of: "\n", with: "\n# "))\n"
        out += "utterance,expected,predicted,correct,latency_ms,difficulty\n"
        for r in rows {
            let u = r.utterance.replacingOccurrences(of: "\"", with: "\"\"")
            out += "\"\(u)\",\(r.expected),\(r.predicted),\(r.correct),\(String(format: "%.0f", r.latencyMS)),\(r.difficulty)\n"
        }
        out += "\nintent,correct,total,recall\n"
        for (intent, c, t) in perIntent {
            out += "\(intent),\(c),\(t),\(String(format: "%.2f", Double(c) / Double(max(t, 1))))\n"
        }
        return out
    }
}

@available(iOS 26.0, *)
enum FMBenchmark {

    struct HoldoutRow {
        let utterance: String
        let expected: String
        let difficulty: String
    }

    /// Parses Resources/FM/fm_holdout.csv (columns: utterance,expected_intent,difficulty).
    static func loadHoldout() -> [HoldoutRow] {
        guard let url = Bundle.main.url(forResource: "fm_holdout", withExtension: "csv"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var rows: [HoldoutRow] = []
        for (i, line) in raw.split(separator: "\n").enumerated() {
            if i == 0 { continue }  // header
            let cols = parseCSVLine(String(line))
            guard cols.count >= 2, !cols[0].isEmpty else { continue }
            rows.append(HoldoutRow(utterance: cols[0], expected: cols[1],
                                   difficulty: cols.count > 2 ? cols[2] : ""))
        }
        return rows
    }

    /// Runs the full holdout through a dedicated classifier instance,
    /// reporting progress after each row. Serial on purpose: one session,
    /// realistic per-turn latency, no rate-limit pressure.
    static func run(progress: @Sendable @escaping (Int, Int) -> Void) async -> FMBenchmarkReport {
        let holdout = loadHoldout()
        let classifier = FMIntentClassifierService()
        await classifier.warmUp()

        var rows: [FMBenchmarkReport.Row] = []
        for (i, item) in holdout.enumerated() {
            let started = ContinuousClock.now
            let result = await classifier.classifyAsync(item.utterance)
            let elapsed = started.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
            rows.append(.init(utterance: item.utterance, expected: item.expected,
                              predicted: result.label, latencyMS: ms,
                              difficulty: item.difficulty))
            progress(i + 1, holdout.count)
        }

        return await FMBenchmarkReport(
            rows: rows,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: deviceModelIdentifier(),
            date: Date()
        )
    }

    // MARK: - Helpers

    /// Minimal CSV field parser (handles quoted fields with embedded commas —
    /// present in the holdout's utterance column).
    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            switch ch {
            case "\"":
                inQuotes.toggle()
            case "," where !inQuotes:
                fields.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @MainActor
    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}
#endif
