import CyberSendData
import CyberSendDomain
import Foundation

// Problem detail store (UI overhaul): one problem, its photo, and its complete attempt
// history. The history is the point of the screen, so attempts come back in reverse
// chronological order (newest first) while the repository keeps its stable ascending order
// for the session screens.

@MainActor
final class ProblemDetailStore: ObservableObject {
    @Published private(set) var climb: Climb?
    @Published private(set) var photo: Photo?
    @Published private(set) var gradeLabel: String?
    @Published private(set) var attempts: [Attempt] = []
    @Published private(set) var lastErrorMessage: String?

    let climbId: String
    private let repos: Repositories

    init(repos: Repositories, climbId: String) {
        self.repos = repos
        self.climbId = climbId
        refresh()
    }

    var sendCount: Int {
        attempts.filter { $0.outcome == .send || $0.outcome == .flash }.count
    }

    var isArchived: Bool {
        climb?.isArchived == true
    }

    func refresh() {
        do {
            climb = try repos.climbs.get(id: climbId)
            guard let climb else {
                attempts = []
                photo = nil
                gradeLabel = nil
                lastErrorMessage = "This problem was deleted."
                return
            }
            let systems = try repos.grades.listSystems()
            gradeLabel = DisplayText.grade(climb, systems: systems)
            photo = try repos.media.listPhotos(filter: ListPhotosFilter(climbId: climb.id)).first
            attempts = try repos.attempts.listByClimb(climbId: climb.id).reversed()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Archives or unarchives this problem. The history is untouched either way (US-26).
    func setArchived(_ archived: Bool) throws {
        if archived {
            _ = try repos.climbs.archive(id: climbId)
        } else {
            _ = try repos.climbs.unarchive(id: climbId)
        }
        refresh()
    }
}
