import CyberSendDomain
import Foundation
import GRDB

// Grade repository (port of src/data/repositories/grade_repository.ts, reconciled to the
// normalized grade_systems and grade_levels tables). Built-in schemes are seeded rows
// (is_builtin = 1); custom schemes are rows created here. Deleting a scheme in use is blocked
// (US-9.4). The default scheme preference lives in settings.

public struct CreateGradeSystemInput: Equatable, Sendable {
    public var name: String
    public var levelLabels: [String]
    public var levelColorHexes: [String?]

    public init(name: String, levelLabels: [String], levelColorHexes: [String?] = []) {
        self.name = name
        self.levelLabels = levelLabels
        self.levelColorHexes = levelColorHexes
    }
}

public protocol GradeRepository: Sendable {
    func listSystems() throws -> [GradeSystem]
    func getSystem(id: String) throws -> GradeSystem?
    func createCustomSystem(_ input: CreateGradeSystemInput) throws -> GradeSystem
    func renameCustomSystem(id: String, name: String) throws -> GradeSystem
    func deleteCustomSystem(id: String) throws
    func setDefaultSystem(id: String) throws
    func defaultSystemID() throws -> String
    /// Throws unless (systemId, levelId) names a known level. A nil levelId clears the grade
    /// and is always valid.
    func assertValidGrade(systemId: String, levelId: String?) throws
}

public struct GRDBGradeRepository: GradeRepository {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func listSystems() throws -> [GradeSystem] {
        try writer.read { db in
            let systemRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM grade_systems ORDER BY is_builtin DESC, created_at, id"
            )
            let levelRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM grade_levels ORDER BY system_id, rank_order"
            )
            var levelsBySystem: [String: [GradeLevel]] = [:]
            for row in levelRows {
                let systemID: String = row["system_id"]
                levelsBySystem[systemID, default: []].append(rowToGradeLevel(row))
            }
            return systemRows.map { row in
                var system = rowToGradeSystem(row)
                system.levels = levelsBySystem[system.id] ?? []
                return system
            }
        }
    }

    public func getSystem(id: String) throws -> GradeSystem? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM grade_systems WHERE id = ?", arguments: [id]) else {
                return nil
            }
            var system = rowToGradeSystem(row)
            system.levels = try Row
                .fetchAll(db, sql: "SELECT * FROM grade_levels WHERE system_id = ? ORDER BY rank_order", arguments: [id])
                .map(rowToGradeLevel)
            return system
        }
    }

    public func createCustomSystem(_ input: CreateGradeSystemInput) throws -> GradeSystem {
        let system = try makeCustomSystem(
            systemId: generateID(),
            name: input.name,
            levelLabels: input.levelLabels,
            colorHexes: input.levelColorHexes
        )
        let timestamp = nowISO8601()
        try writer.write { db in
            try db.withTransaction {
                try $0.execute(
                    sql: """
                    INSERT INTO grade_systems (id, name, is_builtin, created_at, updated_at)
                    VALUES (?, ?, 0, ?, ?)
                    """,
                    arguments: [system.id, system.name, timestamp, timestamp]
                )
                for level in system.levels {
                    try $0.execute(
                        sql: """
                        INSERT INTO grade_levels (id, system_id, label, rank_order, color_hex)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [level.id, system.id, level.label, level.rankOrder, level.colorHex]
                    )
                }
            }
        }
        return system
    }

    public func renameCustomSystem(id: String, name: String) throws -> GradeSystem {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw DomainValidationError("grade_system_name_required", "A custom scheme needs a name.")
        }
        guard var target = try getSystem(id: id) else {
            throw DomainValidationError("grade_system_not_found", "Custom scheme not found.")
        }
        guard !target.isBuiltin else {
            throw DomainValidationError("grade_system_not_found", "Built-in schemes cannot be renamed.")
        }
        target.name = trimmed
        try writer.write { db in
            try db.execute(
                sql: "UPDATE grade_systems SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [trimmed, nowISO8601(), id]
            )
        }
        return target
    }

    public func deleteCustomSystem(id: String) throws {
        if findBuiltinSystem(id) != nil {
            throw DomainValidationError("cannot_delete_builtin_scheme", "Built-in grade schemes cannot be deleted.")
        }
        let inUse = try countClimbsUsing(systemId: id)
        if inUse > 0 {
            let plural = inUse == 1 ? "" : "s"
            throw DomainValidationError(
                "grade_system_in_use",
                "This scheme is used by \(inUse) climb\(plural). Re-grade those climbs first."
            )
        }
        try writer.write { db in
            try db.execute(sql: "DELETE FROM grade_systems WHERE id = ?", arguments: [id])
            guard db.changesCount > 0 else {
                throw DomainValidationError("grade_system_not_found", "Custom scheme not found.")
            }
            let defaultRow = try Row.fetchOne(
                db,
                sql: "SELECT value_json FROM settings WHERE key = ?",
                arguments: [settingsKeyDefaultGradeSystem]
            )
            if let rawDefault = defaultRow.flatMap({ (row: Row) -> String? in row["value_json"] }),
               let decodedDefault = try? JSONDecoder().decode(String.self, from: Data(rawDefault.utf8)),
               decodedDefault == id {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [settingsKeyDefaultGradeSystem])
            }
        }
    }

    public func setDefaultSystem(id: String) throws {
        guard try getSystem(id: id) != nil else {
            throw DomainValidationError("grade_system_not_found", "Grade scheme not found.")
        }
        let encoded = String(data: try JSONEncoder().encode(id), encoding: .utf8) ?? "\"\""
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at
                """,
                arguments: [settingsKeyDefaultGradeSystem, encoded, nowISO8601()]
            )
        }
    }

    public func defaultSystemID() throws -> String {
        try writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT value_json FROM settings WHERE key = ?",
                arguments: [settingsKeyDefaultGradeSystem]
            ) else {
                return defaultGradeSystemID
            }
            let raw: String = row["value_json"]
            guard let decoded = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) else {
                return defaultGradeSystemID
            }
            return decoded
        }
    }

    public func assertValidGrade(systemId: String, levelId: String?) throws {
        guard let levelId else { return }
        guard let system = try getSystem(id: systemId) else {
            throw DomainValidationError("grade_system_not_found", "Unknown grade scheme: \(systemId)")
        }
        guard findLevel(system, levelId: levelId) != nil else {
            throw DomainValidationError(
                "grade_level_not_in_scheme",
                "Level \(levelId) does not exist in scheme \(system.name)."
            )
        }
    }

    private func countClimbsUsing(systemId: String) throws -> Int {
        try writer.read { db in
            let count = try Int64.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM climbs WHERE grade_system_id = ?",
                arguments: [systemId]
            ) ?? 0
            return Int(count)
        }
    }
}
