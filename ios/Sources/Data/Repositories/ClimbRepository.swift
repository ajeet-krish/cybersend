import CyberSendDomain
import Foundation
import GRDB

// Climb repository (port of src/data/repositories/climb_repository.ts, reconciled). Grades are
// stored as (grade_system_id, grade_level_id) references (US-9, never a free string); both are
// validated against the scheme before write. Deleting a climb with attempts is blocked,
// archive is the only path (US-26); since M3 it is also blocked when the climb's owned
// holds are shared through climb_holds or referenced by attempts (US-20).

public struct CreateClimbInput: Equatable, Sendable {
    public var gymId: String
    public var wallId: String?
    public var name: String?
    public var gradeSystemId: String
    public var gradeLevelId: String?
    public var colorCircuit: String?
    public var angleDeg: Double?
    public var notes: String?
    public var categories: [ClimbCategory]

    public init(
        gymId: String,
        wallId: String? = nil,
        name: String? = nil,
        gradeSystemId: String = defaultGradeSystemID,
        gradeLevelId: String? = nil,
        colorCircuit: String? = nil,
        angleDeg: Double? = nil,
        notes: String? = nil,
        categories: [ClimbCategory] = []
    ) {
        self.gymId = gymId
        self.wallId = wallId
        self.name = name
        self.gradeSystemId = gradeSystemId
        self.gradeLevelId = gradeLevelId
        self.colorCircuit = colorCircuit
        self.angleDeg = angleDeg
        self.notes = notes
        self.categories = categories
    }
}

public struct UpdateClimbPatch: Equatable, Sendable {
    /// Moving a problem to another gym (the editor carries a gym picker). The gym must
    /// exist; the foreign key says so and assertGymExists reports it in plain language.
    public var gymId: PatchValue<String>
    public var wallId: PatchValue<String?>
    public var name: PatchValue<String>
    public var gradeSystemId: PatchValue<String>
    public var gradeLevelId: PatchValue<String?>
    public var colorCircuit: PatchValue<String?>
    public var angleDeg: PatchValue<Double?>
    public var notes: PatchValue<String?>
    public var categories: PatchValue<[ClimbCategory]>

    public init(
        gymId: PatchValue<String> = .unchanged,
        wallId: PatchValue<String?> = .unchanged,
        name: PatchValue<String> = .unchanged,
        gradeSystemId: PatchValue<String> = .unchanged,
        gradeLevelId: PatchValue<String?> = .unchanged,
        colorCircuit: PatchValue<String?> = .unchanged,
        angleDeg: PatchValue<Double?> = .unchanged,
        notes: PatchValue<String?> = .unchanged,
        categories: PatchValue<[ClimbCategory]> = .unchanged
    ) {
        self.gymId = gymId
        self.wallId = wallId
        self.name = name
        self.gradeSystemId = gradeSystemId
        self.gradeLevelId = gradeLevelId
        self.colorCircuit = colorCircuit
        self.angleDeg = angleDeg
        self.notes = notes
        self.categories = categories
    }
}

public struct ListClimbsOptions: Equatable, Sendable {
    public var gymId: String?
    public var includeArchived: Bool
    public var includeInactive: Bool
    public var limit: Int?

    public init(gymId: String? = nil, includeArchived: Bool = false, includeInactive: Bool = false, limit: Int? = nil) {
        self.gymId = gymId
        self.includeArchived = includeArchived
        self.includeInactive = includeInactive
        self.limit = limit
    }
}

public protocol ClimbRepository: Sendable {
    func create(_ input: CreateClimbInput) throws -> Climb
    func get(id: String) throws -> Climb?
    func list(options: ListClimbsOptions) throws -> [Climb]
    func update(id: String, patch: UpdateClimbPatch) throws -> Climb
    func archive(id: String) throws -> Climb
    func unarchive(id: String) throws -> Climb
    func setActive(id: String, active: Bool) throws -> Climb
    /// Blocked when attempts exist, when an owned hold is shared with another climb,
    /// or when an owned hold is referenced by any logged attempt. US-26 and US-20:
    /// fall data and shared betas survive gym resets, archive only.
    func delete(id: String) throws
    func countAttempts(id: String) throws -> Int
}

public struct GRDBClimbRepository: ClimbRepository {
    private let writer: any DatabaseWriter
    private let grades: any GradeRepository

    public init(writer: any DatabaseWriter, grades: any GradeRepository) {
        self.writer = writer
        self.grades = grades
    }

    public func create(_ input: CreateClimbInput) throws -> Climb {
        try assertGymExists(gymId: input.gymId)
        guard isClimbAngleValid(input.angleDeg) else {
            throw DomainValidationError("climb_angle_out_of_range", "Climb angle must be between 0 and 90 degrees.")
        }
        try grades.assertValidGrade(systemId: input.gradeSystemId, levelId: input.gradeLevelId)
        let timestamp = nowISO8601()
        let trimmedName = input.name?.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = input.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let climb = Climb(
            id: generateID(),
            gymId: input.gymId,
            wallId: input.wallId,
            name: (trimmedName?.isEmpty ?? true) ? nil : trimmedName,
            gradeSystemId: input.gradeSystemId,
            gradeLevelId: input.gradeLevelId,
            colorCircuit: input.colorCircuit,
            angleDeg: input.angleDeg,
            notes: (trimmedNotes?.isEmpty ?? true) ? nil : trimmedNotes,
            categories: orderedClimbCategories(input.categories),
            isActive: true,
            isArchived: false,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO climbs (id, gym_id, wall_id, board_id, board_problem_id, name, grade_system_id,
                    grade_level_id, grade_norm, color_circuit, angle_deg, notes, categories, is_active,
                    is_archived, created_at, updated_at)
                VALUES (?, ?, ?, NULL, NULL, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    climb.id, climb.gymId, climb.wallId, climb.name, climb.gradeSystemId, climb.gradeLevelId,
                    climb.colorCircuit, climb.angleDeg, climb.notes,
                    encodeClimbCategories(climb.categories), climb.isActive, climb.isArchived,
                    climb.createdAt, climb.updatedAt,
                ]
            )
        }
        return climb
    }

    public func get(id: String) throws -> Climb? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM climbs WHERE id = ?", arguments: [id]).map(rowToClimb)
        }
    }

    public func list(options: ListClimbsOptions) throws -> [Climb] {
        try writer.read { db in
            var clauses: [String] = []
            var arguments: [DatabaseValueConvertible] = []
            if let gymId = options.gymId {
                clauses.append("gym_id = ?")
                arguments.append(gymId)
            }
            if !options.includeArchived {
                clauses.append("is_archived = 0")
            }
            if !options.includeInactive {
                clauses.append("is_active = 1")
            }
            let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
            let limitClause = options.limit.map { "LIMIT \(max(0, $0))" } ?? ""
            return try Row
                .fetchAll(db, sql: "SELECT * FROM climbs \(whereClause) ORDER BY created_at DESC \(limitClause)", arguments: StatementArguments(arguments))
                .map(rowToClimb)
        }
    }

    public func update(id: String, patch: UpdateClimbPatch) throws -> Climb {
        guard var updated = try get(id: id) else {
            throw DomainValidationError("climb_not_found", "Climb not found.")
        }
        let angleDeg = patch.angleDeg.resolve(or: updated.angleDeg)
        guard isClimbAngleValid(angleDeg) else {
            throw DomainValidationError("climb_angle_out_of_range", "Climb angle must be between 0 and 90 degrees.")
        }
        let gradeSystemId = patch.gradeSystemId.resolve(or: updated.gradeSystemId)
        let gradeLevelId = patch.gradeLevelId.resolve(or: updated.gradeLevelId)
        try grades.assertValidGrade(systemId: gradeSystemId, levelId: gradeLevelId)
        if case .set(let gymId) = patch.gymId {
            try assertGymExists(gymId: gymId)
            updated.gymId = gymId
        }

        updated.wallId = patch.wallId.resolve(or: updated.wallId)
        let trimmedName = patch.name.resolve(or: "").trimmingCharacters(in: .whitespaces)
        if case .set = patch.name {
            updated.name = trimmedName.isEmpty ? nil : trimmedName
        }
        updated.gradeSystemId = gradeSystemId
        updated.gradeLevelId = gradeLevelId
        updated.colorCircuit = patch.colorCircuit.resolve(or: updated.colorCircuit)
        updated.angleDeg = angleDeg
        if case .set = patch.notes {
            let trimmedNotes = (patch.notes.resolve(or: nil) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            updated.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        }
        if case .set = patch.categories {
            updated.categories = orderedClimbCategories(patch.categories.resolve(or: []))
        }
        updated.updatedAt = nowISO8601()

        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE climbs SET gym_id = ?, wall_id = ?, board_id = ?, board_problem_id = ?, name = ?,
                    grade_system_id = ?, grade_level_id = ?, grade_norm = ?, color_circuit = ?, angle_deg = ?,
                    notes = ?, categories = ?, is_active = ?, is_archived = ?, updated_at = ? WHERE id = ?
                """,
                arguments: [
                    updated.gymId, updated.wallId, updated.boardId, updated.boardProblemId, updated.name,
                    updated.gradeSystemId, updated.gradeLevelId, updated.gradeNorm, updated.colorCircuit,
                    updated.angleDeg, updated.notes, encodeClimbCategories(updated.categories),
                    updated.isActive, updated.isArchived, updated.updatedAt, id,
                ]
            )
        }
        return updated
    }

    public func archive(id: String) throws -> Climb {
        try setFlag(id: id, column: "is_archived", value: true)
    }

    public func unarchive(id: String) throws -> Climb {
        try setFlag(id: id, column: "is_archived", value: false)
    }

    public func setActive(id: String, active: Bool) throws -> Climb {
        try setFlag(id: id, column: "is_active", value: active)
    }

    public func delete(id: String) throws {
        let attempts = try countAttempts(id: id)
        if attempts > 0 {
            let plural = attempts == 1 ? "" : "s"
            throw DomainValidationError(
                "climb_has_attempts",
                "This climb has \(attempts) logged attempt\(plural). Archive it instead of deleting."
            )
        }
        try assertOwnedHoldsAreUnshared(id: id)
        try writer.write { db in
            try db.execute(sql: "DELETE FROM climbs WHERE id = ?", arguments: [id])
        }
    }

    public func countAttempts(id: String) throws -> Int {
        try writer.read { db in
            let count = try Int64.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM attempts WHERE climb_id = ?",
                arguments: [id]
            ) ?? 0
            return Int(count)
        }
    }

    private func setFlag(id: String, column: String, value: Bool) throws -> Climb {
        try writer.write { db in
            // column comes from this file only, never user input.
            try db.execute(
                sql: "UPDATE climbs SET \(column) = ?, updated_at = ? WHERE id = ?",
                arguments: [value, nowISO8601(), id]
            )
            guard db.changesCount > 0 else {
                throw DomainValidationError("climb_not_found", "Climb not found.")
            }
        }
        guard let climb = try get(id: id) else {
            throw DomainValidationError("climb_not_found", "Climb not found.")
        }
        return climb
    }

    /// A climb owns the holds whose holds.climb_id is the climb (the origin climb,
    /// per the M3 decision record). Delete is blocked when an owned hold is linked
    /// into another climb's climb_holds membership (the delete would cascade the join
    /// row away and orphan that climb's beta) or referenced by any logged attempt as a
    /// fall hold (the attempts FK is ON DELETE SET NULL, which would silently erase
    /// fall data on another climb).
    private func assertOwnedHoldsAreUnshared(id: String) throws {
        let shared = try writer.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM climb_holds
                JOIN holds ON holds.id = climb_holds.hold_id
                WHERE holds.climb_id = ? AND climb_holds.climb_id <> ?
                """,
                arguments: [id, id]
            ) ?? 0
        }
        if shared > 0 {
            throw DomainValidationError(
                "climb_has_shared_holds",
                "This climb owns holds that are shared with other climbs. Unlink them, or archive this climb instead of deleting."
            )
        }
        let referenced = try writer.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM attempts
                JOIN holds ON holds.id = attempts.fall_on_hold_id
                WHERE holds.climb_id = ?
                """,
                arguments: [id]
            ) ?? 0
        }
        if referenced > 0 {
            throw DomainValidationError(
                "climb_holds_in_attempts",
                "This climb owns holds that are referenced by logged attempts. Archive it instead of deleting."
            )
        }
    }

    private func assertGymExists(gymId: String) throws {
        let exists = try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM gyms WHERE id = ?", arguments: [gymId]) ?? 0
        }
        guard exists > 0 else {
            throw DomainValidationError("gym_not_found", "Gym not found.")
        }
    }
}

public extension ClimbRepository {
    func list() throws -> [Climb] {
        try list(options: ListClimbsOptions())
    }
}
