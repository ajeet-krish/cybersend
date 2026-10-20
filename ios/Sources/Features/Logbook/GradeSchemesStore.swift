import Combine
import CyberSendData
import CyberSendDomain
import Foundation

// Grade schemes management store (M2): the grades screen behind LogbookRoute.grades. Lists
// built-in and custom systems (US-9), manages custom systems through the grade repository,
// and owns the default scheme preference (settings key settingsKeyDefaultGradeSystem) that
// grade pickers read. Every write is followed by refresh().

@MainActor
public final class GradeSchemesStore: ObservableObject {
    /// Built-in schemes first, then custom ones, each with its ordered levels.
    @Published public private(set) var systems: [GradeSystem] = []
    /// The persisted default scheme id (settings key settingsKeyDefaultGradeSystem) with
    /// the built-in defaultGradeSystemID fallback when the key is absent or corrupt.
    @Published public private(set) var defaultSystemId: String = defaultGradeSystemID
    @Published public private(set) var lastErrorMessage: String?

    private let repos: Repositories

    public init(repos: Repositories) {
        self.repos = repos
        refresh()
    }

    public func refresh() {
        do {
            systems = try repos.grades.listSystems()
            defaultSystemId = try repos.grades.defaultSystemID()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// The ordered levels of one scheme (throws grade_system_not_found for unknown ids).
    public func levels(forSystem systemId: String) throws -> [GradeLevel] {
        guard let system = try repos.grades.getSystem(id: systemId) else {
            throw DomainValidationError("grade_system_not_found", "Grade scheme not found.")
        }
        return system.levels
    }

    /// Creates a custom scheme with its level labels ordered low to high (US-9). The
    /// domain rejects blank names, blank or duplicate labels before the write.
    @discardableResult
    public func createCustomSystem(name: String, labels: [String]) throws -> GradeSystem {
        let system = try repos.grades.createCustomSystem(
            CreateGradeSystemInput(name: name, levelLabels: labels)
        )
        refresh()
        return system
    }

    /// Renames a scheme. Built-in schemes are protected: the repository throws
    /// grade_system_not_found with the "Built-in schemes cannot be renamed." message,
    /// the same code and message the TypeScript repository uses.
    @discardableResult
    public func rename(id: String, name: String) throws -> GradeSystem {
        let renamed = try repos.grades.renameCustomSystem(id: id, name: name)
        refresh()
        return renamed
    }

    /// Deletes a custom scheme and reloads. Surface codes come from the repository
    /// unchanged: cannot_delete_builtin_scheme for built-ins, and grade_system_in_use
    /// with the blocking climb count in the message (US-9.4). The climb count rides the
    /// error message because counting climbs by scheme would need SQL, which Features
    /// never issues directly (repositories only).
    public func delete(id: String) throws {
        try repos.grades.deleteCustomSystem(id: id)
        refresh()
    }

    /// Persists the default scheme (settings key settingsKeyDefaultGradeSystem, validated
    /// against known schemes by the repository) and reloads.
    public func setDefault(id: String) throws {
        try repos.grades.setDefaultSystem(id: id)
        refresh()
    }
}
