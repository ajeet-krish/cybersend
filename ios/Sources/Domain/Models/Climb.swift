import Foundation

/// Climb entity (port of src/domain/models/climb.ts, reconciled). boardId and boardProblemId
/// are dormant columns (board integration cut from the roadmap, docs/decisions.md) and stay
/// nil in phases 0 to 5. gradeSystemId and gradeLevelId are the (scheme id, level id) pair
/// (US-9, never a free string); gradeNorm is filled by the M4 normalization seam.
public struct Climb: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let gymId: String
    public var wallId: String?
    public var boardId: String?
    public var boardProblemId: String?
    public var name: String?
    public var gradeSystemId: String
    public var gradeLevelId: String?
    public var gradeNorm: Double?
    public var colorCircuit: String?
    public var angleDeg: Double?
    /// Free text problem details (beta, style, what to remember). Added in Migration 004 so
    /// the Problems catalog can carry more than a name and a grade.
    public var notes: String?
    public var isActive: Bool
    public var isArchived: Bool
    public let createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        gymId: String,
        wallId: String? = nil,
        boardId: String? = nil,
        boardProblemId: String? = nil,
        name: String? = nil,
        gradeSystemId: String = defaultGradeSystemID,
        gradeLevelId: String? = nil,
        gradeNorm: Double? = nil,
        colorCircuit: String? = nil,
        angleDeg: Double? = nil,
        notes: String? = nil,
        isActive: Bool = true,
        isArchived: Bool = false,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.gymId = gymId
        self.wallId = wallId
        self.boardId = boardId
        self.boardProblemId = boardProblemId
        self.name = name
        self.gradeSystemId = gradeSystemId
        self.gradeLevelId = gradeLevelId
        self.gradeNorm = gradeNorm
        self.colorCircuit = colorCircuit
        self.angleDeg = angleDeg
        self.notes = notes
        self.isActive = isActive
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public func climbGrade(of climb: Climb) -> ClimbGrade? {
    climbGrade(systemId: climb.gradeSystemId, levelId: climb.gradeLevelId)
}

/// Quick-log shows active, non archived climbs only (US-10).
public func isQuickLoggable(_ climb: Climb) -> Bool {
    climb.isActive && !climb.isArchived
}

public func isClimbAngleValid(_ angleDeg: Double?) -> Bool {
    isValidAngle(angleDeg)
}
