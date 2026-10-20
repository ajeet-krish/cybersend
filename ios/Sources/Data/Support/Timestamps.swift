import Foundation

// Timestamps are ISO 8601 UTC text per docs/schema.sql conventions, formatted exactly like the
// TypeScript spec's Date.toISOString() (for example 2026-10-19T14:03:11.123Z) so exports and
// golden fixtures stay comparable across the two ports.

public func nowISO8601() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

/// Formats a fixed date as ISO 8601 UTC text with milliseconds (test and fixture support).
public func iso8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
