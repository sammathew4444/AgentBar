import Foundation

/// Parses the timestamps collectors write. Python's `isoformat()` gives microseconds and a
/// `+00:00` offset (`2026-09-14T12:00:00.123456+00:00`), which `ISO8601DateFormatter` rejects
/// with its fractional-seconds option, so the fraction is dropped before parsing. A timestamp
/// without an offset is read as UTC, as `limit_window_open` in omarchy-agent-usage-claude does.
enum OmarchyDate {
    static func parse(_ string: String) -> Date? {
        var text = string.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        if text.range(of: #"(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) == nil {
            text += "Z"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// UTC in Python's `isoformat()` shape, as collectors write `updatedAt`:
    /// `2026-09-14T15:00:00.123456+00:00`, with the fraction only when it isn't zero.
    static func isoformat(_ date: Date) -> String {
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded(.down))
        let seconds = micros >= 0 ? micros / 1_000_000 : (micros - 999_999) / 1_000_000
        let fraction = micros - seconds * 1_000_000
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        var text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        if fraction != 0 { text += String(format: ".%06lld", fraction) }
        return text + "+00:00"
    }
}
