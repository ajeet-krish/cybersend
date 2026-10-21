import Foundation

/// Climb category tags (UI overhaul): what kind of climb it is, as opposed to how hard it
/// is. A climb carries a set of them, picked from a fixed list so filters and summaries can
/// rely on canonical tokens. They are descriptive only: no rule in the domain depends on
/// them. Stored comma separated in climbs.categories, in declaration order, which keeps the
/// bytes deterministic for exports.
public enum ClimbCategory: String, CaseIterable, Codable, Sendable {
    case slab
    case vertical
    case overhang
    case roof
    case crimpy
    case slopey
    case pinchy
    case dyno
    case coordination
    case campus
    case comp
    case technical
    case powerful
    case endurance

    /// The label the climber reads on the category buttons.
    public var title: String {
        switch self {
        case .slab: return "Slab"
        case .vertical: return "Vertical"
        case .overhang: return "Overhang"
        case .roof: return "Roof"
        case .crimpy: return "Crimpy"
        case .slopey: return "Slopey"
        case .pinchy: return "Pinchy"
        case .dyno: return "Dyno"
        case .coordination: return "Coordination"
        case .campus: return "Campus"
        case .comp: return "Comp"
        case .technical: return "Technical"
        case .powerful: return "Powerful"
        case .endurance: return "Endurance"
        }
    }
}

/// Every category in display order (declaration order, so the button grid is stable).
public let climbCategories: [ClimbCategory] = ClimbCategory.allCases

/// Parses the stored comma separated tokens into categories, ignoring unknown or blank
/// tokens so a file written by a newer build still imports and simply loses the tags this
/// build does not know. Deduplicates while keeping declaration order.
public func parseClimbCategories(_ stored: String?) -> [ClimbCategory] {
    guard let stored else { return [] }
    let tokens = Set(stored.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    return ClimbCategory.allCases.filter { tokens.contains($0.rawValue) }
}

/// Normalizes a picked set to declaration order, which is the order the database stores and
/// the order the editor and catalog show.
public func orderedClimbCategories(_ categories: [ClimbCategory]) -> [ClimbCategory] {
    ClimbCategory.allCases.filter { categories.contains($0) }
}

/// Encodes categories for storage: declaration order, comma separated, nil when empty so a
/// climb with no tags reads as no value rather than an empty string.
public func encodeClimbCategories(_ categories: [ClimbCategory]) -> String? {
    let ordered = orderedClimbCategories(categories)
    guard !ordered.isEmpty else { return nil }
    return ordered.map(\.rawValue).joined(separator: ",")
}

/// Climb entity (port of src/domain/models/climb.ts, reconciled). boardId and boardProblemId
/// are dormant columns (board integration cut from the roadmap, docs/decisions.md) and stay
/// nil in phases 0 to 5. gradeSystemId and gradeLevelId are the (scheme id, level id) pair
/// (US-9, never a free string); gradeNorm is filled by the M4 normalization seam.
public struct Climb: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// Mutable since the UI overhaul: the problem editor can move a climb to another gym.
    /// The repository validates the target gym before writing.
    public var gymId: String
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
    /// Descriptive category tags (Migration 005), empty when none are set.
    public var categories: [ClimbCategory]
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
        categories: [ClimbCategory] = [],
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
        self.categories = categories
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
