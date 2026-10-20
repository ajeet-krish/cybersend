import Combine
import CyberSendData
import CyberSendDomain
import Foundation

// Logbook tab store (M2): gyms, the persisted default gym selection, the open session,
// quick-log climbs, grade schemes, and recent history. Swift port of the TypeScript
// zustand logbook store (src/features/sessions/logbook_store.ts) onto the per feature
// ObservableObject convention (docs/decisions.md, 2026-10-20 M2). Repositories are read
// and written synchronously on the main actor and every write is followed by refresh().

@MainActor
public final class LogbookStore: ObservableObject {
    /// Active (not archived) gyms for the picker and quick log (US-8).
    @Published public private(set) var gyms: [Gym] = []
    /// Every gym including archived ones, for the managers screen and history badges.
    @Published public private(set) var allGyms: [Gym] = []
    /// The selected gym, resolved from the persisted default (settings key
    /// settingsKeyDefaultGymID) on every refresh.
    @Published public private(set) var selectedGymId: String?
    /// The one open session (US-11.2), nil when none is open.
    @Published public private(set) var openSession: Session?
    /// Active, not archived climbs of the selected gym: the quick-log set (US-10).
    @Published public private(set) var quickLogClimbs: [Climb] = []
    @Published public private(set) var gradeSystems: [GradeSystem] = []
    /// Reverse chronological history for the logbook and sessions tabs (US-22.1).
    @Published public private(set) var recentSessions: [SessionSummary] = []
    @Published public private(set) var lastErrorMessage: String?

    private let repos: Repositories

    public init(repos: Repositories) {
        self.repos = repos
        refresh()
    }

    /// The selected gym, or nil when no active gym is selected.
    public var selectedGym: Gym? {
        gyms.first { $0.id == selectedGymId }
    }

    /// Reloads every published value and resolves the selected gym: the persisted default
    /// when it names an active gym, otherwise the first active gym, otherwise nil.
    public func refresh() {
        do {
            gyms = try repos.gyms.list(includeArchived: false)
            allGyms = try repos.gyms.list(includeArchived: true)
            openSession = try repos.sessions.getOpen()
            gradeSystems = try repos.grades.listSystems()
            recentSessions = try repos.sessions.list(limit: 500)
            selectedGymId = resolveSelectedGymId()
            quickLogClimbs = try loadQuickLogClimbs()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Selects a gym (nil clears the selection) and persists it as the default gym so the
    /// next launch preselects it. The selection always updates; the settings write is best
    /// effort so a storage failure never leaves the UI out of sync.
    public func selectGym(_ gymId: String?) {
        selectedGymId = gymId
        do {
            if let gymId {
                try repos.settings.setJSON(key: settingsKeyDefaultGymID, value: gymId)
            } else {
                try repos.settings.remove(key: settingsKeyDefaultGymID)
            }
            quickLogClimbs = try loadQuickLogClimbs()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Starts a session at the selected gym (US-11). The one open session rule is checked
    /// before the write and throws the same open_session_exists code the repository and the
    /// TypeScript spec use, so the logbook screen can surface the existing session.
    public func startSession() throws -> Session {
        if let existing = try repos.sessions.getOpen() {
            openSession = existing
            throw DomainValidationError(
                "open_session_exists",
                "A session is already open. Close it before starting another one."
            )
        }
        guard let gymId = selectedGymId else {
            throw DomainValidationError(
                "gym_not_selected",
                "Select a gym before starting a session."
            )
        }
        let session = try repos.sessions.create(CreateSessionInput(gymId: gymId))
        refresh()
        return session
    }

    // MARK: - Private

    /// The persisted default gym when it is active, otherwise the first active gym.
    private func resolveSelectedGymId() -> String? {
        let activeIds = Set(gyms.map(\.id))
        let storedId = try? repos.settings.getJSON(key: settingsKeyDefaultGymID, as: String.self)
        if let storedId, activeIds.contains(storedId) {
            return storedId
        }
        return gyms.first?.id
    }

    /// Quick-log climbs of the selected gym; defaults exclude archived and inactive rows
    /// (ListClimbsOptions, matching the TypeScript refreshClimbs quick-log query).
    private func loadQuickLogClimbs() throws -> [Climb] {
        guard let gymId = selectedGymId else { return [] }
        return try repos.climbs.list(options: ListClimbsOptions(gymId: gymId))
    }
}
