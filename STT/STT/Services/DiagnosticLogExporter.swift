// DiagnosticLogExporter.swift
// STT
//
// Queries OSLogStore for all com.stt.module entries and exports them as a
// plain-text file. Used during active diagnosis to capture the DIAG-RC*
// log markers in a shareable form.

import OSLog
import Foundation

/// Fetches and formats `com.stt.module` log entries from `OSLogStore`.
///
/// `OSLogStore` requires no special entitlement for the current process's own
/// subsystem. The query window defaults to the last 15 minutes, which is
/// enough to cover a full diagnostic session without flooding the file.
@MainActor
public final class DiagnosticLogExporter {

    public static let shared = DiagnosticLogExporter()
    private init() {}

    public enum ExportError: LocalizedError {
        case storeUnavailable(Error)
        case noEntriesFound

        public var errorDescription: String? {
            switch self {
            case .storeUnavailable(let e): return "OSLogStore unavailable: \(e.localizedDescription)"
            case .noEntriesFound:          return "No log entries found for com.stt.module in the last 15 minutes."
            }
        }
    }

    /// Fetches log entries and writes them to a temp file, returning its URL.
    ///
    /// Runs off the main actor so the UI stays responsive during the query.
    public func export(windowMinutes: Int = 15) async throws -> URL {
        let text = try await Task.detached(priority: .userInitiated) {
            try Self.fetchEntries(windowMinutes: windowMinutes)
        }.value
        return try writeToTemp(text)
    }

    // MARK: - Private

    private static func fetchEntries(windowMinutes: Int) throws -> String {
        let store: OSLogStore
        do {
            store = try OSLogStore(scope: .currentProcessIdentifier)
        } catch {
            throw ExportError.storeUnavailable(error)
        }

        let since = Date().addingTimeInterval(-Double(windowMinutes) * 60)
        let position = store.position(date: since)

        let predicate = NSPredicate(format: "subsystem == %@", "com.stt.module")
        let entries = try store.getEntries(at: position, matching: predicate)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = [
            "STT Diagnostic Log Export",
            "Subsystem : com.stt.module",
            "Window    : last \(windowMinutes) minutes (since \(formatter.string(from: since)))",
            "Generated : \(formatter.string(from: Date()))",
            String(repeating: "─", count: 80),
            ""
        ]

        var count = 0
        for entry in entries {
            guard let logEntry = entry as? OSLogEntryLog else { continue }
            let level: String
            switch logEntry.level {
            case .debug:     level = "DEBUG  "
            case .info:      level = "INFO   "
            case .notice:    level = "NOTICE "
            case .error:     level = "ERROR  "
            case .fault:     level = "FAULT  "
            default:         level = "OTHER  "
            }
            let ts = formatter.string(from: logEntry.date)
            lines.append("[\(ts)] [\(level)] [\(logEntry.category)] \(logEntry.composedMessage)")
            count += 1
        }

        if count == 0 { throw ExportError.noEntriesFound }

        lines.append("")
        lines.append(String(repeating: "─", count: 80))
        lines.append("Total entries: \(count)")
        return lines.joined(separator: "\n")
    }

    private func writeToTemp(_ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let name = "stt_diag_\(Int(Date().timeIntervalSince1970)).txt"
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
