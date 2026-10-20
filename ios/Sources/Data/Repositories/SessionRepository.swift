import CyberSendDomain
import Foundation
import GRDB

// Session repository (port of src/data/repositories/session_repository.ts). Rules: at most one
// open session at a time (US-11.2), closing is idempotent (US-11.3), RPE is validated in the
// domain layer regardless of source (US-11.1).

public struct CreateSessionInput: Equatable, Sendable {
    public var gymId: String
    public var startedAt: String?
    public var notes: String?

    public init(gymId: String, startedAt: String? = nil, notes: String? = nil) {
        self.gymId = gymId
        self.startedAt = startedAt
        self.notes = notes
    }
}

public struct CloseSessionInput: Equatable, Sendable {
    /// nil means "now" (closing time defaults to the current instant).
    public var endedAt: String?
    public var rpe: PatchValue<Int?>
    public var notes: PatchValue<String?>

    public init(endedAt: String? = nil, rpe: PatchValue<Int?> = .unchanged, notes: PatchValue<String?> = .unchanged) {
        self.endedAt = endedAt
        self.rpe = rpe
        self.notes = notes
    }
}

public struct UpdateSessionPatch: Equatable, Sendable {
    public var rpe: PatchValue<Int?>
    public var notes: PatchValue<String?>

    public init(rpe: PatchValue<Int?> = .unchanged, notes: PatchValue<String?> = .unchanged) {
        self.rpe = rpe
        self.notes = notes
    }
}

public protocol SessionRepository: Sendable {
    func create(_ input: CreateSessionInput) throws -> Session
    func getOpen() throws -> Session?
    func get(id: String) throws -> Session?
    func close(id: String, input: CloseSessionInput) throws -> Session
    func update(id: String, patch: UpdateSessionPatch) throws -> Session
    /// Reverse chronological history with attempt counts (US-22.1).
    func list(limit: Int) throws -> [SessionSummary]
    func delete(id: String) throws
}

public extension SessionRepository {
    func close(id: String) throws -> Session {
        try close(id: id, input: CloseSessionInput())
    }

    func update(id: String) throws -> Session {
        try update(id: id, patch: UpdateSessionPatch())
    }

    func list() throws -> [SessionSummary] {
        try list(limit: 200)
    }
}

public struct GRDBSessionRepository: SessionRepository {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func create(_ input: CreateSessionInput) throws -> Session {
        if try getOpen() != nil {
            throw DomainValidationError(
                "open_session_exists",
                "A session is already open. Close it before starting another one."
            )
        }
        let gymExists = try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM gyms WHERE id = ?", arguments: [input.gymId]) ?? 0
        }
        guard gymExists > 0 else {
            throw DomainValidationError("gym_not_found", "Gym not found.")
        }
        let timestamp = nowISO8601()
        let session = Session(
            id: generateID(),
            gymId: input.gymId,
            startedAt: input.startedAt ?? timestamp,
            endedAt: nil,
            rpe: nil,
            notes: input.notes,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (id, gym_id, started_at, ended_at, rpe, notes, created_at, updated_at)
                VALUES (?, ?, ?, NULL, NULL, ?, ?, ?)
                """,
                arguments: [session.id, session.gymId, session.startedAt, session.notes, session.createdAt, session.updatedAt]
            )
        }
        return session
    }

    public func getOpen() throws -> Session? {
        try writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM sessions WHERE ended_at IS NULL ORDER BY started_at DESC LIMIT 1"
            ).map(rowToSession)
        }
    }

    public func get(id: String) throws -> Session? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id]).map(rowToSession)
        }
    }

    // Idempotent: closing an already closed session returns it unchanged (US-11.3).
    public func close(id: String, input: CloseSessionInput) throws -> Session {
        try writer.write { db in
            try db.withTransaction { tx in
                let existing = try requireSession(tx: tx, id: id)
                guard isSessionOpen(existing) else { return existing }
                let rpe = try validateRPE(input.rpe.resolve(or: existing.rpe))
                let endedAt = input.endedAt ?? nowISO8601()
                let notes = input.notes.resolve(or: existing.notes)
                let updatedAt = nowISO8601()
                try tx.execute(
                    sql: "UPDATE sessions SET ended_at = ?, rpe = ?, notes = ?, updated_at = ? WHERE id = ?",
                    arguments: [endedAt, rpe, notes, updatedAt, id]
                )
                return Session(
                    id: existing.id,
                    gymId: existing.gymId,
                    startedAt: existing.startedAt,
                    endedAt: endedAt,
                    rpe: rpe,
                    notes: notes,
                    createdAt: existing.createdAt,
                    updatedAt: updatedAt
                )
            }
        }
    }

    // Edits notes and RPE on any session (used by session detail).
    public func update(id: String, patch: UpdateSessionPatch) throws -> Session {
        try writer.write { db in
            let existing = try requireSession(tx: db, id: id)
            let rpe = try validateRPE(patch.rpe.resolve(or: existing.rpe))
            let notes = patch.notes.resolve(or: existing.notes)
            let updatedAt = nowISO8601()
            try db.execute(
                sql: "UPDATE sessions SET rpe = ?, notes = ?, updated_at = ? WHERE id = ?",
                arguments: [rpe, notes, updatedAt, id]
            )
            return Session(
                id: existing.id,
                gymId: existing.gymId,
                startedAt: existing.startedAt,
                endedAt: existing.endedAt,
                rpe: rpe,
                notes: notes,
                createdAt: existing.createdAt,
                updatedAt: updatedAt
            )
        }
    }

    public func list(limit: Int) throws -> [SessionSummary] {
        try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT sessions.*, (SELECT COUNT(*) FROM attempts WHERE attempts.session_id = sessions.id) AS attempt_count
                FROM sessions ORDER BY sessions.started_at DESC LIMIT ?
                """,
                arguments: [limit]
            )
            .map { try rowToSessionSummary($0) }
        }
    }

    public func delete(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id])
        }
    }

    private func requireSession(tx: Database, id: String) throws -> Session {
        guard let row = try Row.fetchOne(tx, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id]) else {
            throw DomainValidationError("session_not_found", "Session not found.")
        }
        return rowToSession(row)
    }
}
