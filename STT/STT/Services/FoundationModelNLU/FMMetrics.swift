// FMMetrics.swift
// STT — FoundationModelNLU (evaluation sample; see docs/FM_SAMPLE_PLAN.md)
//
// Lightweight per-call metrics for the FM path: every classification logs a
// record (utterance, label, self-rating, latency, failure), and the in-memory
// tail feeds the benchmark report and the on-screen latency badge. Local
// only — nothing leaves the device.

import Foundation
import os.log

struct FMMetricRecord: Sendable {
    let timestamp: Date
    let utterance: String
    let label: String
    /// Model self-rating (0–1). Display-only; uncalibrated by definition.
    let selfRating: Double
    let duration: Duration
    let failed: Bool

    var latencyMS: Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }
}

/// Global sink so the classifier (an actor) can record without holding a
/// reference to UI-owned state. Bounded ring buffer — the sample never grows
/// memory unbounded during a long benchmark.
enum FMMetrics {
    private static let logger = Logger(subsystem: "com.stt.module", category: "FMMetrics")
    private static let lock = NSLock()
    /// Guarded by `lock` — every access below takes it. The annotation opts the
    /// static out of actor-isolation checking; the lock is the real guarantee.
    nonisolated(unsafe) private static var records: [FMMetricRecord] = []
    private static let capacity = 2_000

    static func record(utterance: String, label: String,
                       selfRating: Double, duration: Duration, failed: Bool) {
        let rec = FMMetricRecord(timestamp: Date(), utterance: utterance, label: label,
                                 selfRating: selfRating, duration: duration, failed: failed)
        lock.lock()
        records.append(rec)
        if records.count > capacity { records.removeFirst(records.count - capacity) }
        lock.unlock()
        logger.info("FM turn: \(label, privacy: .public) \(rec.latencyMS, format: .fixed(precision: 0))ms selfRating=\(selfRating, format: .fixed(precision: 2))\(failed ? " FAILED" : "")")
    }

    /// Most recent record (drives the per-turn latency badge).
    static var latest: FMMetricRecord? {
        lock.lock(); defer { lock.unlock() }
        return records.last
    }

    /// Snapshot for the benchmark report.
    static func snapshot() -> [FMMetricRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        records.removeAll()
    }
}
