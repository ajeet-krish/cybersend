import CyberSendDomain
import Foundation
import GRDB

// Hold repository (port of src/data/repositories/hold_repository.ts, reconciled to holds.role
// and holds.color_family). Coordinates are normalized 0..1 and validated in the domain layer
// before any write (docs/decisions.md, normalized coordinates at the domain boundary).

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
    func listByClimb(climbId: String) throws -> [Hold]
    func get(id: String) throws -> Hold?
    func update(id: String, patch: UpdateHoldPatch) throws -> Hold
    func idsForClimb(climbId: String) throws -> [String]
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
        }
        return hold
    }

    public func listByClimb(climbId: String) throws -> [Hold] {
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
