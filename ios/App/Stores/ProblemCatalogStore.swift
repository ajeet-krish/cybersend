import CyberSendData
import CyberSendDomain
import Foundation

// Problems catalog store (UI overhaul): the Problems tab lists every climb of the selected
// gym as a problem, with the summary the climber actually wants (attempts, sends, last
// attempt). Repositories stay the only SQL surface (US-13); the view reads published
// values. Personal scale, so one query per problem for its summary is cheaper than a
// bespoke aggregate query and keeps the SQL surface unchanged.

/// Per problem rollup for the catalog row: how much it has been tried, how often it went
/// down, and when it was last tried.
struct ProblemSummary: Equatable, Sendable {
    let attemptCount: Int
    let sendCount: Int
    let lastAttemptAt: String?

    static let empty = ProblemSummary(attemptCount: 0, sendCount: 0, lastAttemptAt: nil)

    var isSent: Bool { sendCount > 0 }
}

/// One catalog row: the climb plus its precomputed grade label and summary.
struct ProblemRow: Identifiable, Equatable {
    let climb: Climb
    let gradeLabel: String?
    let summary: ProblemSummary

    var id: String { climb.id }
}

@MainActor
final class ProblemCatalogStore: ObservableObject {
    @Published private(set) var rows: [ProblemRow] = []
    @Published private(set) var gradeSystems: [GradeSystem] = []
    @Published private(set) var lastErrorMessage: String?

    /// Archived problems are hidden by default: archiving is how a problem leaves the
    /// catalog without losing its history (US-26).
    @Published var includeArchived = false {
        didSet {
            guard oldValue != includeArchived else { return }
            refresh(gymId: selectedGymId)
        }
    }

    private(set) var selectedGymId: String?
    private let repos: Repositories

    init(repos: Repositories) {
        self.repos = repos
    }

    /// Number of active (not archived) problems, for the empty state wording.
    var activeCount: Int {
        rows.filter { !$0.climb.isArchived }.count
    }

    func refresh(gymId: String?) {
        selectedGymId = gymId
        do {
            gradeSystems = try repos.grades.listSystems()
            guard let gymId else {
                rows = []
                lastErrorMessage = nil
                return
            }
            let climbs = try repos.climbs.list(
                options: ListClimbsOptions(gymId: gymId, includeArchived: includeArchived)
            )
            rows = try climbs.map { climb in
                ProblemRow(
                    climb: climb,
                    gradeLabel: DisplayText.grade(climb, systems: gradeSystems),
                    summary: try summary(for: climb.id)
                )
            }
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
        refresh(gymId: selectedGymId)
    }

    private func summary(for climbId: String) throws -> ProblemSummary {
        let attempts = try repos.attempts.listByClimb(climbId: climbId)
        guard !attempts.isEmpty else { return .empty }
        let sends = attempts.filter { $0.outcome == .send || $0.outcome == .flash }.count
        return ProblemSummary(
            attemptCount: attempts.count,
            sendCount: sends,
            lastAttemptAt: attempts.map(\.attemptedAt).max()
        )
    }
}
