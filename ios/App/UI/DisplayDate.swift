import Foundation

// Tolerant ISO 8601 display parsing in one place (review 2026-10-20: display date parsing
// was duplicated in two shell files and accepted only the fractional seconds shape, so a
// stamp without milliseconds rendered as raw text). Stored timestamps are ISO 8601 UTC
// with or without fractional seconds (docs/schema.sql conventions); both shapes render
// through this helper in the local time zone. Main actor only: the cached formatters are
// mutable Foundation objects and every caller is a SwiftUI screen (Swift 6 strict
// concurrency makes the isolation explicit).

@MainActor
enum DisplayDate {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Medium date, short time in the local zone. Returns the raw text when neither ISO
    /// shape parses, so a corrupt stamp stays visible instead of silently wrong.
    static func string(from isoText: String) -> String {
        guard let date = fractionalFormatter.date(from: isoText) ?? plainFormatter.date(from: isoText) else {
            return isoText
        }
        return displayFormatter.string(from: date)
    }
}
