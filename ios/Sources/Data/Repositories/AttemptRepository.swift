import CyberSendDomain
import Foundation
import GRDB

// Attempt repository (port of src/data/repositories/attempt_repository.ts, reconciled).
// logAttempt is the canonical multi table transaction: it computes the next attempt number per
// (session_id, climb_id), validates the outcome in the domain layer (flash implies first
// attempt, fall hold must belong to the climb), and inserts one row atomically (US-12).

public struct LogAttemptInput: Equatable, Sendable {
    public var sessionId: String
    public var climbId: String
    public var outcome: AttemptOutcome
    public var fallOnHoldId: String?
    public var notes: String?
    public var videoId: String?
    /// nil means "now" (the attempt moment defaults to the current instant).
    public var attemptedAt: String?
    /// Per climb effort rating 1 to 10, nil when the climber did not record one.
    public var rpe: Int?

    public init(
        sessionId: String,
        climbId: String,
        outcome: AttemptOutcome,
        fallOnHoldId: String? = nil,
        notes: String? = nil,
        videoId: String? = nil,
        attemptedAt: String? = nil,
        rpe: Int? = nil
    ) {
        self.sessionId = sessionId
        self.climbId = climbId
        self.outcome = outcome
        self.fallOnHoldId = fallOnHoldId
        self.notes = notes
        self.videoId = videoId
        self.attemptedAt = attemptedAt
        self.rpe = rpe
    }
}

public struct LogAttemptResult: Equatable, Sendable {
    public let attempt: Attempt
    public let warnings: [String]

    public init(attempt: Attempt, warnings: [String]) {
        self.attempt = attempt
        self.warnings = warnings
    }
}

public struct UpdateAttemptPatch: Equatable, Sendable {
    public var outcome: PatchValue<AttemptOutcome>
    public var fallOnHoldId: PatchValue<String?>
    public var notes: PatchValue<String?>
    public var rpe: PatchValue<Int?>

    public init(
        outcome: PatchValue<AttemptOutcome> = .unchanged,
        fallOnHoldId: PatchValue<String?> = .unchanged,
        notes: PatchValue<String?> = .unchanged,
        rpe: PatchValue<Int?> = .unchanged
    ) {
        self.outcome = outcome
        self.fallOnHoldId = fallOnHoldId
        self.notes = notes
        self.rpe = rpe
    }
}

public protocol AttemptRepository: Sendable {
    func logAttempt(_ input: LogAttemptInput) throws -> LogAttemptResult
    /// Re-validates outcome and fall hold against the climb, same rules as logAttempt.
    func updateAttempt(id: String, patch: UpdateAttemptPatch) throws -> Attempt
    func get(id: String) throws -> Attempt?
    func listBySession(sessionId: String) throws -> [Attempt]
    func listByClimb(climbId: String) throws -> [Attempt]
    /// Most recent attempts across every session, newest first (home screen recent climbs).
    func listRecent(limit: Int) throws -> [Attempt]
    func countByClimb(climbId: String) throws -> Int
    func delete(id: String) throws
}

public struct GRDBAttemptRepository: AttemptRepository {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func logAttempt(_ input: LogAttemptInput) throws -> LogAttemptResult {
        try writer.write { db in
            try db.withTransaction { tx in
                try assertSessionExists(tx: tx, sessionId: input.sessionId)
                try assertClimbExists(tx: tx, climbId: input.climbId)
                let attemptNo = try nextAttemptNo(tx: tx, sessionId: input.sessionId, climbId: input.climbId)
                let climbHoldIds = try climbHoldIDs(tx: tx, climbId: input.climbId)
                let validation = try validateAttempt(
                    input: AttemptInput(
                        outcome: input.outcome,
                        fallOnHoldId: input.fallOnHoldId,
                        notes: input.notes,
                        videoId: input.videoId
                    ),
                    context: AttemptRuleContext(attemptNo: attemptNo, climbHoldIds: climbHoldIds)
                )
                let attempt = Attempt(
                    id: generateID(),
                    sessionId: input.sessionId,
                    climbId: input.climbId,
                    attemptNo: attemptNo,
                    outcome: input.outcome,
                    fallOnHoldId: validation.fallOnHoldId,
                    videoId: input.videoId,
                    notes: input.notes,
                    attemptedAt: input.attemptedAt ?? nowISO8601(),
                    // Same 1 to 10 domain as the session RPE: rejected here so the UI
                    // surfaces a validation message instead of a CHECK constraint error.
                    rpe: try validateRPE(input.rpe)
                )
                try tx.execute(
                    sql: """
                    INSERT INTO attempts (id, session_id, climb_id, attempt_no, outcome, fall_on_hold_id,
                        video_id, notes, attempted_at, rpe) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        attempt.id, attempt.sessionId, attempt.climbId, attempt.attemptNo, attempt.outcome.rawValue,
                        attempt.fallOnHoldId, attempt.videoId, attempt.notes, attempt.attemptedAt, attempt.rpe,
                    ]
                )
                return LogAttemptResult(attempt: attempt, warnings: validation.warnings)
            }
        }
    }

    public func updateAttempt(id: String, patch: UpdateAttemptPatch) throws -> Attempt {
        try writer.write { db in
            try db.withTransaction { tx in
                let existing = try requireAttempt(tx: tx, id: id)
                let outcome = patch.outcome.resolve(or: existing.outcome)
                let fallOnHoldId = patch.fallOnHoldId.resolve(or: existing.fallOnHoldId)
                let notes = patch.notes.resolve(or: existing.notes)
                let rpe = try validateRPE(patch.rpe.resolve(or: existing.rpe))
                let climbHoldIds = try climbHoldIDs(tx: tx, climbId: existing.climbId)
                let validation = try validateAttempt(
                    input: AttemptInput(outcome: outcome, fallOnHoldId: fallOnHoldId, notes: notes, videoId: existing.videoId),
                    context: AttemptRuleContext(attemptNo: existing.attemptNo, climbHoldIds: climbHoldIds)
                )
                try tx.execute(
                    sql: "UPDATE attempts SET outcome = ?, fall_on_hold_id = ?, notes = ?, rpe = ? WHERE id = ?",
                    arguments: [outcome.rawValue, validation.fallOnHoldId, notes, rpe, id]
                )
                return Attempt(
                    id: existing.id,
                    sessionId: existing.sessionId,
                    climbId: existing.climbId,
                    attemptNo: existing.attemptNo,
                    outcome: outcome,
                    fallOnHoldId: validation.fallOnHoldId,
                    videoId: existing.videoId,
                    notes: notes,
                    attemptedAt: existing.attemptedAt,
                    rpe: rpe
                )
            }
        }
    }

    public func get(id: String) throws -> Attempt? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM attempts WHERE id = ?", arguments: [id]).map { try rowToAttempt($0) }
        }
    }

    public func listBySession(sessionId: String) throws -> [Attempt] {
        try writer.read { db in
            try Row
                .fetchAll(db, sql: "SELECT * FROM attempts WHERE session_id = ? ORDER BY attempted_at, attempt_no", arguments: [sessionId])
                .map { try rowToAttempt($0) }
        }
    }

    public func listByClimb(climbId: String) throws -> [Attempt] {
        try writer.read { db in
            try Row
                .fetchAll(db, sql: "SELECT * FROM attempts WHERE climb_id = ? ORDER BY attempted_at, attempt_no", arguments: [climbId])
                .map { try rowToAttempt($0) }
        }
    }

    /// Most recent attempts across every session, newest first. The home screen's recent
    /// climbs block needs the climbs a climber touched last, which is an attempts question,
    /// not a climbs one (climbs carry no last-touched column).
    public func listRecent(limit: Int = 100) throws -> [Attempt] {
        try writer.read { db in
            try Row
                .fetchAll(
                    db,
                    sql: "SELECT * FROM attempts ORDER BY attempted_at DESC, attempt_no DESC LIMIT ?",
                    arguments: [max(0, limit)]
                )
                .map { try rowToAttempt($0) }
        }
    }

    public func countByClimb(climbId: String) throws -> Int {
        try writer.read { db in
            let count = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM attempts WHERE climb_id = ?", arguments: [climbId]) ?? 0
            return Int(count)
        }
    }

    public func delete(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM attempts WHERE id = ?", arguments: [id])
        }
    }

    private func nextAttemptNo(tx: Database, sessionId: String, climbId: String) throws -> Int {
        let next = try Int64.fetchOne(
            tx,
            sql: "SELECT COALESCE(MAX(attempt_no), 0) + 1 FROM attempts WHERE session_id = ? AND climb_id = ?",
            arguments: [sessionId, climbId]
        ) ?? 1
        return Int(next)
    }

    private func climbHoldIDs(tx: Database, climbId: String) throws -> [String] {
        // M3 (US-20): fall hold validation is climb_holds membership, not ownership
        // through holds.climb_id, so a borrowed hold is a valid fall hold too.
        try String.fetchAll(
            tx,
            sql: "SELECT hold_id FROM climb_holds WHERE climb_id = ?",
            arguments: [climbId]
        )
    }

    private func requireAttempt(tx: Database, id: String) throws -> Attempt {
        guard let row = try Row.fetchOne(tx, sql: "SELECT * FROM attempts WHERE id = ?", arguments: [id]) else {
            throw DomainValidationError("attempt_not_found", "Attempt not found.")
        }
        return try rowToAttempt(row)
    }

    private func assertSessionExists(tx: Database, sessionId: String) throws {
        let exists = try Int64.fetchOne(tx, sql: "SELECT COUNT(*) FROM sessions WHERE id = ?", arguments: [sessionId]) ?? 0
        guard exists > 0 else {
            throw DomainValidationError("session_not_found", "Session not found.")
        }
    }

    private func assertClimbExists(tx: Database, climbId: String) throws {
        let exists = try Int64.fetchOne(tx, sql: "SELECT COUNT(*) FROM climbs WHERE id = ?", arguments: [climbId]) ?? 0
        guard exists > 0 else {
            throw DomainValidationError("climb_not_found", "Climb not found.")
        }
    }
}
