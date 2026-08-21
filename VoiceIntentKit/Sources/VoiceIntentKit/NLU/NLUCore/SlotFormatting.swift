// SlotFormatting.swift
// STT
//
// Display helpers for NLU slot parameters — human-readable slot names and
// friendly date formatting (ISO "2026-06-06T09:00" → "Tomorrow, 9:00 AM").
// Shared by the result card and the follow-up banner.

import Foundation

enum SlotFormatting {

    /// Human-readable label for a slot key.
    static func displayName(_ key: String) -> String {
        switch key {
        case "date-time":  return "When"
        case "name":       return "What"
        case "MemoryName": return "Memory"
        case "recurrence": return "Repeat"
        default:           return key.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    /// Display value for a slot — pretty-prints date-time slots, passes others through.
    static func displayValue(_ value: String, forKey key: String) -> String {
        if key == "date-time", let pretty = prettyDate(value) { return pretty }
        return value
    }

    // MARK: - Date formatting

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Formats an ISO date-time string relative to `now`:
    /// "Today, 9:00 AM" · "Tomorrow, 9:00 AM" · "Friday, 5:00 PM" · "Jun 14, 9:00 AM".
    static func prettyDate(_ iso: String, now: Date = Date()) -> String? {
        guard let date = isoParser.date(from: iso) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        let time = timeFormatter.string(from: date)
        if cal.isDateInToday(date)    { return "Today, \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow, \(time)" }

        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: now),
                                      to: cal.startOfDay(for: date)).day ?? 0
        let dayFormatter = DateFormatter()
        dayFormatter.locale = .current
        dayFormatter.dateFormat = (days > 1 && days < 7) ? "EEEE" : "EEE, MMM d"
        return "\(dayFormatter.string(from: date)), \(time)"
    }
}
