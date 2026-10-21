import CyberSendDomain
import Foundation
import GRDB

// Hold repository (port of src/data/repositories/hold_repository.ts, reconciled to holds.role
// and holds.color_family). Coordinates are normalized 0..1 and validated in the domain layer
// before any write (docs/decisions.md, normalized coordinates at the domain boundary).
// Since M3 (US-20) holds stay keyed by their origin climb (holds.climb_id) while
// membership and beta order live in climb_holds; every membership write goes through
// create, createRestoring, linkHold, unlinkHold, and setSequence so the two can never
// drift.

public let defaultHoldRadiusNorm: Double = 0.02

public struct CreateHoldInput: Equatable, Sendable {
    public var climbId: String
    public var xNorm: Double
    public var yNorm: Double
    public var radiusNorm: Double
    public var role: HoldRole?
    public var colorFamily: String?
    public var source: HoldSource
    public var ordinal: Int?

    public init(
        climbId: String,
        xNorm: Double,
        yNorm: Double,
        radiusNorm: Double = defaultHoldRadiusNorm,
        role: HoldRole? = nil,
        colorFamily: String? = nil,
        source: HoldSource = .manual,
        ordinal: Int? = nil
    ) {
        self.climbId = climbId
        self.xNorm = xNorm
        self.yNorm = yNorm
        self.radiusNorm = radiusNorm
        self.role = role
        self.colorFamily = colorFamily
        self.source = source
        self.ordinal = ordinal
    }
}

public struct UpdateHoldPatch: Equatable, Sendable {
    public var xNorm: PatchValue<Double>
    public var yNorm: PatchValue<Double>
    public var radiusNorm: PatchValue<Double>
    public var role: PatchValue<HoldRole?>
    public var colorFamily: PatchValue<String?>
    public var ordinal: PatchValue<Int?>

    public init(
        xNorm: PatchValue<Double> = .unchanged,
        yNorm: PatchValue<Double> = .unchanged,
        radiusNorm: PatchValue<Double> = .unchanged,
        role: PatchValue<HoldRole?> = .unchanged,
        colorFamily: PatchValue<String?> = .unchanged,
        ordinal: PatchValue<Int?> = .unchanged
    ) {
        self.xNorm = xNorm
        self.yNorm = yNorm
        self.radiusNorm = radiusNorm
        self.role = role
        self.colorFamily = colorFamily
        self.ordinal = ordinal
    }
}

public protocol HoldRepository: Sendable {
    func create(_ input: CreateHoldInput) throws -> Hold
    /// Re-inserts an exact hold value with its original id and timestamps, mirroring
    /// create()'s origin membership write. Tagging undo of a delete restores the
    /// identical row, so canvas identity, selection, and beta order survive (M3).
    func createRestoring(_ hold: Hold) throws
    /// Holds linked to the climb through climb_holds membership (US-20), in beta order:
    /// sequence ascending with nil sequences last, then creation time.
    func listByClimb(climbId: String) throws -> [Hold]
    /// Holds owned by the climb (holds.climb_id, the origin climb), in ordinal order.
    func listOwnedByClimb(climbId: String) throws -> [Hold]
    func get(id: String) throws -> Hold?
    func update(id: String, patch: UpdateHoldPatch) throws -> Hold
    func idsForClimb(climbId: String) throws -> [String]
    /// Links a hold into the climb's membership with an optional beta sequence.
    /// Membership writes through this API are the only way to share a hold across
    /// climbs (docs/decisions.md 2026-10-20 M3); re-linking updates the sequence.
    func linkHold(climbId: String, holdId: String, sequence: Int?) throws -> ClimbHold
    /// Removes the membership row only: the hold, its origin climb, and every attempt
    /// stay untouched (US-20.4).
    func unlinkHold(climbId: String, holdId: String) throws
    func setSequence(climbId: String, holdId: String, sequence: Int?) throws -> ClimbHold
    /// Every climb that links the hold, in link creation order.
    func linkedClimbIds(holdId: String) throws -> [String]
    /// The hold ids linked to the climb, in beta order (same order as listByClimb).
    func idsLinkedToClimb(climbId: String) throws -> [String]
    func delete(id: String) throws
    func deleteByClimb(climbId: String) throws
}

public struct GRDBHoldRepository: HoldRepository {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func create(_ input: CreateHoldInput) throws -> Hold {
        try validateHoldCoords(xNorm: input.xNorm, yNorm: input.yNorm, radiusNorm: input.radiusNorm)
        let timestamp = nowISO8601()
        let hold = Hold(
            id: generateID(),
            climbId: input.climbId,
            xNorm: input.xNorm,
            yNorm: input.yNorm,
            radiusNorm: input.radiusNorm,
            role: input.role,
            colorFamily: input.colorFamily,
            source: input.source,
            ordinal: input.ordinal,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO holds (id, climb_id, x_norm, y_norm, radius_norm, role, color_family, source,
                    ordinal, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    hold.id, hold.climbId, hold.xNorm, hold.yNorm, hold.radiusNorm, hold.role?.rawValue,
                    hold.colorFamily, hold.source.rawValue, hold.ordinal, hold.createdAt, hold.updatedAt,
                ]
            )
            // A new hold joins its origin climb's membership with the ordinal as the
            // beta sequence, mirroring the Migration 002 backfill, so listByClimb sees
            // it without a separate link call.
            try db.execute(
                sql: """
                INSERT INTO climb_holds (climb_id, hold_id, sequence, created_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(climb_id, hold_id) DO NOTHING
                """,
                arguments: [hold.climbId, hold.id, hold.ordinal, hold.createdAt]
            )
        }
        return hold
    }

    public func createRestoring(_ hold: Hold) throws {
        try validateHoldCoords(xNorm: hold.xNorm, yNorm: hold.yNorm, radiusNorm: hold.radiusNorm)
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO holds (id, climb_id, x_norm, y_norm, radius_norm, role, color_family, source,
                    ordinal, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    hold.id, hold.climbId, hold.xNorm, hold.yNorm, hold.radiusNorm, hold.role?.rawValue,
                    hold.colorFamily, hold.source.rawValue, hold.ordinal, hold.createdAt, hold.updatedAt,
                ]
            )
            // Mirror create(): the restored hold rejoins its origin climb's membership
            // with the ordinal as the beta sequence, so undo returns the exact row set
            // the delete removed (the delete cascaded this membership away).
            try db.execute(
                sql: """
                INSERT INTO climb_holds (climb_id, hold_id, sequence, created_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(climb_id, hold_id) DO NOTHING
                """,
                arguments: [hold.climbId, hold.id, hold.ordinal, hold.createdAt]
            )
        }
    }

    public func listByClimb(climbId: String) throws -> [Hold] {
        try writer.read { db in
            try Row
                .fetchAll(
                    db,
                    sql: """
                    SELECT holds.* FROM climb_holds
                    JOIN holds ON holds.id = climb_holds.hold_id
                    WHERE climb_holds.climb_id = ?
                    ORDER BY climb_holds.sequence IS NULL, climb_holds.sequence, climb_holds.created_at,
                        climb_holds.rowid
                    """,
                    arguments: [climbId]
                )
                .map { try rowToHold($0) }
        }
    }

    public func listOwnedByClimb(climbId: String) throws -> [Hold] {
        try writer.read { db in
            try Row
                .fetchAll(
                    db,
                    sql: "SELECT * FROM holds WHERE climb_id = ? ORDER BY ordinal IS NULL, ordinal, created_at",
                    arguments: [climbId]
                )
                .map { try rowToHold($0) }
        }
    }

    public func get(id: String) throws -> Hold? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM holds WHERE id = ?", arguments: [id]).map { try rowToHold($0) }
        }
    }

    public func update(id: String, patch: UpdateHoldPatch) throws -> Hold {
        guard var hold = try get(id: id) else {
            throw DomainValidationError("hold_not_found", "Hold not found.")
        }
        hold.xNorm = patch.xNorm.resolve(or: hold.xNorm)
        hold.yNorm = patch.yNorm.resolve(or: hold.yNorm)
        hold.radiusNorm = patch.radiusNorm.resolve(or: hold.radiusNorm)
        hold.role = patch.role.resolve(or: hold.role)
        hold.colorFamily = patch.colorFamily.resolve(or: hold.colorFamily)
        hold.ordinal = patch.ordinal.resolve(or: hold.ordinal)
        hold.updatedAt = nowISO8601()
        try validateHoldCoords(xNorm: hold.xNorm, yNorm: hold.yNorm, radiusNorm: hold.radiusNorm)
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE holds SET x_norm = ?, y_norm = ?, radius_norm = ?, role = ?, color_family = ?, ordinal = ?,
                    updated_at = ? WHERE id = ?
                """,
                arguments: [
                    hold.xNorm, hold.yNorm, hold.radiusNorm, hold.role?.rawValue, hold.colorFamily, hold.ordinal,
                    hold.updatedAt, id,
                ]
            )
        }
        return hold
    }

    public func idsForClimb(climbId: String) throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM holds WHERE climb_id = ?", arguments: [climbId])
        }
    }

    public func linkHold(climbId: String, holdId: String, sequence: Int?) throws -> ClimbHold {
        try writer.write { db in
            try assertHoldExists(holdId: holdId, on: db)
            try assertClimbExists(climbId: climbId, on: db)
            // Re-linking keeps the original membership timestamp and refreshes the
            // sequence, so relinking is an ordering update, not a new share.
            try db.execute(
                sql: """
                INSERT INTO climb_holds (climb_id, hold_id, sequence, created_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(climb_id, hold_id) DO UPDATE SET sequence = excluded.sequence
                """,
                arguments: [climbId, holdId, sequence, nowISO8601()]
            )
        }
        guard let climbHold = try climbHold(climbId: climbId, holdId: holdId) else {
            throw DomainValidationError("climb_hold_not_found", "Climb hold link not found.")
        }
        return climbHold
    }

    public func unlinkHold(climbId: String, holdId: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM climb_holds WHERE climb_id = ? AND hold_id = ?",
                arguments: [climbId, holdId]
            )
        }
    }

    public func setSequence(climbId: String, holdId: String, sequence: Int?) throws -> ClimbHold {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE climb_holds SET sequence = ? WHERE climb_id = ? AND hold_id = ?",
                arguments: [sequence, climbId, holdId]
            )
            guard db.changesCount > 0 else {
                throw DomainValidationError("climb_hold_not_found", "Hold is not linked to this climb.")
            }
        }
        guard let climbHold = try climbHold(climbId: climbId, holdId: holdId) else {
            throw DomainValidationError("climb_hold_not_found", "Hold is not linked to this climb.")
        }
        return climbHold
    }

    public func linkedClimbIds(holdId: String) throws -> [String] {
        try writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT climb_id FROM climb_holds WHERE hold_id = ? ORDER BY created_at",
                arguments: [holdId]
            )
        }
    }

    public func idsLinkedToClimb(climbId: String) throws -> [String] {
        try writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT hold_id FROM climb_holds WHERE climb_id = ?
                ORDER BY sequence IS NULL, sequence, created_at, rowid
                """,
                arguments: [climbId]
            )
        }
    }

    private func climbHold(climbId: String, holdId: String) throws -> ClimbHold? {
        try writer.read { db in
            try Row
                .fetchOne(
                    db,
                    sql: "SELECT * FROM climb_holds WHERE climb_id = ? AND hold_id = ?",
                    arguments: [climbId, holdId]
                )
                .map(rowToClimbHold)
        }
    }

    private func assertHoldExists(holdId: String, on db: Database) throws {
        let exists = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM holds WHERE id = ?", arguments: [holdId]) ?? 0
        guard exists > 0 else {
            throw DomainValidationError("hold_not_found", "Hold not found.")
        }
    }

    private func assertClimbExists(climbId: String, on db: Database) throws {
        let exists = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM climbs WHERE id = ?", arguments: [climbId]) ?? 0
        guard exists > 0 else {
            throw DomainValidationError("climb_not_found", "Climb not found.")
        }
    }

    public func delete(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM holds WHERE id = ?", arguments: [id])
        }
    }

    public func deleteByClimb(climbId: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM holds WHERE climb_id = ?", arguments: [climbId])
        }
    }
}
