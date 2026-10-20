import Foundation

/// Grade scheme and level entities (port of src/domain/models/grade.ts, reconciled to the
/// normalized grade_systems and grade_levels tables per docs/schema.sql and US-9: grade is
/// stored as (grade_system_id, grade_level_id), never a free string).

public struct GradeLevel: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var label: String
    public var rankOrder: Int
    public var colorHex: String?

    public init(id: String, label: String, rankOrder: Int, colorHex: String? = nil) {
        self.id = id
        self.label = label
        self.rankOrder = rankOrder
        self.colorHex = colorHex
    }
}

public struct GradeSystem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var isBuiltin: Bool
    public var levels: [GradeLevel]

    public init(id: String, name: String, isBuiltin: Bool, levels: [GradeLevel]) {
        self.id = id
        self.name = name
        self.isBuiltin = isBuiltin
        self.levels = levels
    }
}

/// The (scheme id, level id) pair a climb's grade is stored as.
public struct ClimbGrade: Equatable, Sendable {
    public let systemId: String
    public let levelId: String

    public init(systemId: String, levelId: String) {
        self.systemId = systemId
        self.levelId = levelId
    }
}

public func climbGrade(systemId: String, levelId: String?) -> ClimbGrade? {
    guard let levelId else { return nil }
    return ClimbGrade(systemId: systemId, levelId: levelId)
}

public func findLevel(_ system: GradeSystem, levelId: String) -> GradeLevel? {
    system.levels.first { $0.id == levelId }
}

/// Returns the level label for a (scheme, level) pair, or nil when either is unknown.
public func gradeLabel(_ system: GradeSystem?, levelId: String?) -> String? {
    guard let system, let levelId else { return nil }
    return findLevel(system, levelId: levelId)?.label
}
