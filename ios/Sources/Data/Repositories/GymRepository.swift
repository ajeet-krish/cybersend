import CyberSendDomain
import Foundation
import GRDB

// Gym repository, the gym aggregate root (port of src/data/repositories/gym_repository.ts).
// Gym archival uses gyms.is_archived (docs/schema.sql reconciled, requirements US-8). Walls
// belong to the gym aggregate.

public struct CreateGymInput: Equatable, Sendable {
    public var name: String
    public var timezone: String?

    public init(name: String, timezone: String? = nil) {
        self.name = name
        self.timezone = timezone
    }
}

public struct CreateWallInput: Equatable, Sendable {
    public var gymId: String
    public var name: String?
    public var angleDeg: Double?
    public var angleLabel: String?

    public init(gymId: String, name: String? = nil, angleDeg: Double? = nil, angleLabel: String? = nil) {
        self.gymId = gymId
        self.name = name
        self.angleDeg = angleDeg
        self.angleLabel = angleLabel
    }
}

public protocol GymRepository: Sendable {
    func create(_ input: CreateGymInput) throws -> Gym
    func get(id: String) throws -> Gym?
    /// Archived gyms are hidden from new session pickers by default but stay visible in history.
    func list(includeArchived: Bool) throws -> [Gym]
    func rename(id: String, name: String) throws -> Gym
    func setArchived(id: String, archived: Bool) throws -> Gym
    func archive(id: String) throws -> Gym
    func unarchive(id: String) throws -> Gym
    func createWall(_ input: CreateWallInput) throws -> Wall
    func listWalls(gymId: String, includeInactive: Bool) throws -> [Wall]
    func setWallActive(id: String, active: Bool) throws
}

public struct GRDBGymRepository: GymRepository {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func create(_ input: CreateGymInput) throws -> Gym {
        let name = input.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw DomainValidationError("gym_name_required", "A gym needs a name.")
        }
        let timestamp = nowISO8601()
        let gym = Gym(id: generateID(), name: name, timezone: input.timezone, isArchived: false, createdAt: timestamp, updatedAt: timestamp)
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO gyms (id, name, timezone, is_archived, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [gym.id, gym.name, gym.timezone, gym.isArchived, gym.createdAt, gym.updatedAt]
            )
        }
        return gym
    }

    public func get(id: String) throws -> Gym? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM gyms WHERE id = ?", arguments: [id]).map(rowToGym)
        }
    }

    public func list(includeArchived: Bool) throws -> [Gym] {
        try writer.read { db in
            let sql = includeArchived
                ? "SELECT * FROM gyms ORDER BY name COLLATE NOCASE, created_at"
                : "SELECT * FROM gyms WHERE is_archived = 0 ORDER BY name COLLATE NOCASE, created_at"
            return try Row.fetchAll(db, sql: sql).map(rowToGym)
        }
    }

    public func rename(id: String, name: String) throws -> Gym {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw DomainValidationError("gym_name_required", "A gym needs a name.")
        }
        try writer.write { db in
            try db.execute(
                sql: "UPDATE gyms SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [trimmed, nowISO8601(), id]
            )
            guard db.changesCount > 0 else {
                throw DomainValidationError("gym_not_found", "Gym not found.")
            }
        }
        return try requireGym(id: id)
    }

    public func setArchived(id: String, archived: Bool) throws -> Gym {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE gyms SET is_archived = ?, updated_at = ? WHERE id = ?",
                arguments: [archived, nowISO8601(), id]
            )
            guard db.changesCount > 0 else {
                throw DomainValidationError("gym_not_found", "Gym not found.")
            }
        }
        return try requireGym(id: id)
    }

    public func archive(id: String) throws -> Gym {
        try setArchived(id: id, archived: true)
    }

    public func unarchive(id: String) throws -> Gym {
        try setArchived(id: id, archived: false)
    }

    // MARK: - Walls

    public func createWall(_ input: CreateWallInput) throws -> Wall {
        guard isValidAngle(input.angleDeg) else {
            throw DomainValidationError("wall_angle_out_of_range", "Wall angle must be between 0 and 90 degrees.")
        }
        let timestamp = nowISO8601()
        let wall = Wall(
            id: generateID(),
            gymId: input.gymId,
            name: input.name,
            angleDeg: input.angleDeg,
            angleLabel: input.angleLabel,
            isActive: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO walls (id, gym_id, name, angle_deg, angle_label, is_active, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [wall.id, wall.gymId, wall.name, wall.angleDeg, wall.angleLabel, wall.isActive, wall.createdAt, wall.updatedAt]
            )
        }
        return wall
    }

    public func listWalls(gymId: String, includeInactive: Bool) throws -> [Wall] {
        try writer.read { db in
            let sql = includeInactive
                ? "SELECT * FROM walls WHERE gym_id = ? ORDER BY name COLLATE NOCASE, created_at"
                : "SELECT * FROM walls WHERE gym_id = ? AND is_active = 1 ORDER BY name COLLATE NOCASE, created_at"
            return try Row.fetchAll(db, sql: sql, arguments: [gymId]).map(rowToWall)
        }
    }

    public func setWallActive(id: String, active: Bool) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE walls SET is_active = ?, updated_at = ? WHERE id = ?",
                arguments: [active, nowISO8601(), id]
            )
        }
    }

    private func requireGym(id: String) throws -> Gym {
        guard let gym = try get(id: id) else {
            throw DomainValidationError("gym_not_found", "Gym not found.")
        }
        return gym
    }
}

public extension GymRepository {
    func list() throws -> [Gym] {
        try list(includeArchived: false)
    }

    func listWalls(gymId: String) throws -> [Wall] {
        try listWalls(gymId: gymId, includeInactive: false)
    }
}
