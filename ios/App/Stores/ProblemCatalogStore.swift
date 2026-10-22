import CyberSendData
import CyberSendDomain
import Foundation

// Problems catalog store (UI overhaul): the Problems tab lists every climb as a problem,
// across gyms, with the summary the climber actually wants (attempts, sends, last attempt)
// and the filters that narrow the catalog (gym, level, category, climb status).
// Repositories stay the only SQL surface (US-13); the view reads published values. Personal
// scale, so one query per problem for its summary is cheaper than a bespoke aggregate query
// and keeps the SQL surface unchanged. Filtering happens in memory over the loaded rows,
// which is why the whole catalog is loaded once and the filters are plain published state.

/// Per problem rollup for the catalog row: how much it has been tried, how often it went
/// down, and when it was last tried. Flash and a plain send are counted separately so the
/// status filter can tell "flash" from "sent".
struct ProblemSummary: Equatable, Sendable {
    let attemptCount: Int
    let sendCount: Int
    let flashCount: Int
    let lastAttemptAt: String?

    static let empty = ProblemSummary(attemptCount: 0, sendCount: 0, flashCount: 0, lastAttemptAt: nil)

    /// Sent covers both flashes and plain sends, which is what the catalog badge means.
    var isSent: Bool { sendCount > 0 || flashCount > 0 }
}

/// One catalog row: the climb plus its precomputed grade label, gym name, and summary.
struct ProblemRow: Identifiable, Equatable {
    let climb: Climb
    let gymName: String?
    let gradeLabel: String?
    let summary: ProblemSummary

    var id: String { climb.id }
}

/// A level filter option. The pair is the identity, because a level id only means something
/// inside its scheme, and two schemes can both label a level "V4".
struct CatalogLevelOption: Identifiable, Equatable {
    let id: String
    let label: String
}

/// Climb status filter: sent (at least one send), flash (at least one flash), or ongoing
/// (neither yet).
enum ClimbStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case sent
    case flash
    case ongoing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Any status"
        case .sent: return "Sent"
        case .flash: return "Flash"
        case .ongoing: return "Ongoing"
        }
    }
}

@MainActor
final class ProblemCatalogStore: ObservableObject {
    @Published private(set) var allRows: [ProblemRow] = []
    @Published private(set) var gradeSystems: [GradeSystem] = []
    @Published private(set) var gyms: [Gym] = []
    @Published private(set) var lastErrorMessage: String?

    /// Filters. Nil means "no filter" for gym, level, and category; the status filter has
    /// an explicit all case.
    @Published var filterGymId: String? = nil
    @Published var filterLevelId: String? = nil
    @Published var filterCategory: ClimbCategory? = nil
    @Published var filterStatus: ClimbStatusFilter = .all

    /// Archived problems are hidden by default: archiving is how a problem leaves the
    /// catalog without losing its history (US-26).
    @Published var includeArchived = false {
        didSet {
            guard oldValue != includeArchived else { return }
            refresh()
        }
    }

    private let repos: Repositories

    init(repos: Repositories) {
        self.repos = repos
    }

    /// The visible rows: the loaded catalog with every filter applied.
    var rows: [ProblemRow] {
        allRows.filter { row in
            if let filterGymId, row.climb.gymId != filterGymId { return false }
            if let filterLevelId, levelKey(row.climb) != filterLevelId { return false }
            if let filterCategory, !row.climb.categories.contains(filterCategory) { return false }
            switch filterStatus {
            case .all:
                break
            case .sent:
                if row.summary.sendCount == 0 { return false }
            case .flash:
                if row.summary.flashCount == 0 { return false }
            case .ongoing:
                if row.summary.isSent { return false }
            }
            return true
        }
    }

    /// True when a filter hides everything, so the empty state can offer to clear them
    /// instead of claiming the catalog is empty.
    var hasActiveFilters: Bool {
        filterGymId != nil || filterLevelId != nil || filterCategory != nil || filterStatus != .all
    }

    /// The level options present in the catalog, in scheme and level order rather than
    /// alphabetically (so V2 sorts before V10).
    var levelOptions: [CatalogLevelOption] {
        var options: [CatalogLevelOption] = []
        var seen = Set<String>()
        for climb in allRows.map(\.climb).sorted(by: { gradeSortKey($0) < gradeSortKey($1) }) {
            guard climb.gradeLevelId != nil else { continue }
            let key = levelKey(climb)
            guard seen.insert(key).inserted else { continue }
            let label = DisplayText.grade(climb, systems: gradeSystems) ?? key
            options.append(CatalogLevelOption(id: key, label: label))
        }
        return options
    }

    var gymFilterTitle: String {
        guard let filterGymId else { return "All gyms" }
        return gyms.first(where: { $0.id == filterGymId })?.name ?? "Gym"
    }

    var levelFilterTitle: String {
        guard let filterLevelId else { return "Any level" }
        return levelOptions.first(where: { $0.id == filterLevelId })?.label ?? "Level"
    }

    var categoryFilterTitle: String {
        filterCategory?.title ?? "Any category"
    }

    func refresh() {
        do {
            gradeSystems = try repos.grades.listSystems()
            gyms = try repos.gyms.list(includeArchived: true)
            let climbs = try repos.climbs.list(
                options: ListClimbsOptions(includeArchived: includeArchived)
            )
            let gymNames = Dictionary(uniqueKeysWithValues: gyms.map { ($0.id, $0.name) })
            allRows = try climbs.map { climb in
                ProblemRow(
                    climb: climb,
                    gymName: gymNames[climb.gymId],
                    gradeLabel: DisplayText.grade(climb, systems: gradeSystems),
                    summary: try summary(for: climb.id)
                )
            }
            // A filter that no longer matches anything (a deleted level, a removed gym)
            // would silently empty the list, so clear the stale ones on reload.
            clearStaleFilters()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Archives or unarchives one problem and reloads the catalog, so the row moves out of
    /// (or back into) the list the moment the write lands.
    func setArchived(climbId: String, archived: Bool) throws {
        if archived {
            _ = try repos.climbs.archive(id: climbId)
        } else {
            _ = try repos.climbs.unarchive(id: climbId)
        }
        refresh()
    }

    func clearFilters() {
        filterGymId = nil
        filterLevelId = nil
        filterCategory = nil
        filterStatus = .all
    }

    private func clearStaleFilters() {
        if let filterGymId, !gyms.contains(where: { $0.id == filterGymId }) {
            self.filterGymId = nil
        }
        if let filterLevelId, !levelOptions.contains(where: { $0.id == filterLevelId }) {
            self.filterLevelId = nil
        }
    }

    private func levelKey(_ climb: Climb) -> String {
        "\(climb.gradeSystemId)|\(climb.gradeLevelId ?? "")"
    }

    /// Sort key for level options: scheme order first, then the level's rank in that scheme,
    /// so V2 comes before V10 and a second scheme stays grouped.
    private func gradeSortKey(_ climb: Climb) -> (Int, Int) {
        let systemIndex = gradeSystems.firstIndex(where: { $0.id == climb.gradeSystemId }) ?? gradeSystems.count
        let levels = gradeSystems.first(where: { $0.id == climb.gradeSystemId })?.levels ?? []
        let levelIndex = levels.firstIndex(where: { $0.id == climb.gradeLevelId }) ?? levels.count
        return (systemIndex, levelIndex)
    }

    private func summary(for climbId: String) throws -> ProblemSummary {
        let attempts = try repos.attempts.listByClimb(climbId: climbId)
        guard !attempts.isEmpty else { return .empty }
        let sends = attempts.filter { $0.outcome == .send }.count
        let flashes = attempts.filter { $0.outcome == .flash }.count
        return ProblemSummary(
            attemptCount: attempts.count,
            sendCount: sends,
            flashCount: flashes,
            lastAttemptAt: attempts.map(\.attemptedAt).max()
        )
    }
}
