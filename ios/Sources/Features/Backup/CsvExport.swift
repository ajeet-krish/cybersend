import CyberSendDomain
import Foundation

// CSV export (RFC 4180) for sessions, attempts, and climbs (US-14.2, port of
// src/features/backup/csv.ts). Export only; full fidelity import is JSON (requirements
// section 7). Column names stay byte identical with the TypeScript spec: attempts keep
// the old fell_on_hold_id and created_at names for the reconciled fall_on_hold_id and
// attempted_at columns, and climbs' grade_system column carries the scheme id.

private let crlf = "\r\n"

public enum CsvEntity: String, CaseIterable, Sendable {
    case sessions
    case attempts
    case climbs
}

/// RFC 4180 field escaping (port of csv_escape): null becomes empty, fields with a
/// comma, quote, CR, or LF get wrapped in quotes with inner quotes doubled. Scalar
/// level checks match the TypeScript /[",\r\n]/ regex (Swift Characters would fold a
/// CRLF pair into one grapheme).
public func csvEscape(_ field: String?) -> String {
    guard let field else { return "" }
    let specials: Set<Unicode.Scalar> = ["\"", ",", "\r", "\n"]
    if field.unicodeScalars.contains(where: { specials.contains($0) }) {
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return field
}

/// Joins headers and rows with CRLF, trailing CRLF included (port of to_csv).
public func toCsv(headers: [String], rows: [[String?]]) -> String {
    var lines = [headers.map(csvEscape).joined(separator: ",")]
    for row in rows {
        lines.append(row.map(csvEscape).joined(separator: ","))
    }
    return lines.joined(separator: crlf) + crlf
}

public let sessionCsvHeaders: [String] = [
    "id",
    "gym_id",
    "started_at",
    "ended_at",
    "rpe",
    "notes",
    "created_at",
    "updated_at",
]

public func sessionsToCsv(_ sessions: [Session]) -> String {
    toCsv(
        headers: sessionCsvHeaders,
        rows: sessions.map { session in
            [
                session.id,
                session.gymId,
                session.startedAt,
                session.endedAt,
                session.rpe.map(String.init),
                session.notes,
                session.createdAt,
                session.updatedAt,
            ]
        }
    )
}

public let attemptCsvHeaders: [String] = [
    "id",
    "session_id",
    "climb_id",
    "attempt_no",
    "outcome",
    "fell_on_hold_id",
    "notes",
    "created_at",
    // Version 3 addition (M4): per attempt RPE. Appended so the earlier columns keep
    // their positions for anything that reads this file by index.
    "rpe",
]

public func attemptsToCsv(_ attempts: [Attempt]) -> String {
    toCsv(
        headers: attemptCsvHeaders,
        rows: attempts.map { attempt in
            [
                attempt.id,
                attempt.sessionId,
                attempt.climbId,
                String(attempt.attemptNo),
                attempt.outcome.rawValue,
                attempt.fallOnHoldId,
                attempt.notes,
                attempt.attemptedAt,
                attempt.rpe.map(String.init),
            ]
        }
    )
}

public let climbCsvHeaders: [String] = [
    "id",
    "gym_id",
    "wall_id",
    "name",
    "grade_system",
    "grade_level_id",
    "color_circuit",
    "angle_deg",
    "is_active",
    "is_archived",
    "created_at",
    "updated_at",
    // Version 4 addition (Problems catalog): problem details, appended so earlier
    // columns keep their positions.
    "notes",
    // Version 5 addition (UI overhaul): comma separated category tokens, same rule.
    "categories",
]

public func climbsToCsv(_ climbs: [Climb]) -> String {
    toCsv(
        headers: climbCsvHeaders,
        rows: climbs.map { climb in
            [
                climb.id,
                climb.gymId,
                climb.wallId,
                climb.name,
                climb.gradeSystemId,
                climb.gradeLevelId,
                climb.colorCircuit,
                climb.angleDeg.map(jsNumberString),
                climb.isActive ? "1" : "0",
                climb.isArchived ? "1" : "0",
                climb.createdAt,
                climb.updatedAt,
                climb.notes,
                encodeClimbCategories(climb.categories),
            ]
        }
    )
}
