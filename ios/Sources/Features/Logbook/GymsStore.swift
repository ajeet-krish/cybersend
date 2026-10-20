import Combine
import CyberSendData
import CyberSendDomain
import Foundation

// Gyms management store (M2): the gym managers screen behind LogbookRoute.gyms. Gyms are
// listed with archived rows included (US-8), creations, renames, and archival go through
// the gym repository (the gym aggregate root), and every write is followed by refresh().

@MainActor
public final class GymsStore: ObservableObject {
    /// Every gym including archived ones, ordered by name (US-8.4 keeps archived visible
    /// on the managers screen).
    @Published public private(set) var gyms: [Gym] = []
    @Published public private(set) var lastErrorMessage: String?

    private let repos: Repositories

    public init(repos: Repositories) {
        self.repos = repos
        refresh()
    }

    /// The active (not archived) subset, for pickers that hide archived gyms.
    public var activeGyms: [Gym] {
        gyms.filter { !$0.isArchived }
    }

    public func refresh() {
        do {
            gyms = try repos.gyms.list(includeArchived: true)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Creates a gym (name required, trimmed by the repository) and reloads.
    @discardableResult
    public func createGym(name: String) throws -> Gym {
        let gym = try repos.gyms.create(CreateGymInput(name: name))
        refresh()
        return gym
    }

    /// Renames a gym (throws gym_name_required for blank names, gym_not_found for unknown
    /// ids) and reloads.
    @discardableResult
    public func rename(id: String, name: String) throws -> Gym {
        let gym = try repos.gyms.rename(id: id, name: name)
        refresh()
        return gym
    }

    /// Archives or unarchives a gym and reloads. Archived gyms leave new session pickers
    /// but stay visible in history (US-8).
    @discardableResult
    public func setArchived(id: String, archived: Bool) throws -> Gym {
        let gym = try repos.gyms.setArchived(id: id, archived: archived)
        refresh()
        return gym
    }

    /// The gym's active walls (the gym repository owns the walls subtable).
    public func walls(forGym gymId: String) throws -> [Wall] {
        try repos.gyms.listWalls(gymId: gymId)
    }
}
