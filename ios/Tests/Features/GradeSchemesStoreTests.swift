import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Grade schemes store tests (M2): built-in plus custom listing, level lookup, delete in
// use surfacing the climb count, built-in protection, and the persisted default scheme.

@Suite("GradeSchemesStore")
@MainActor
struct GradeSchemesStoreTests {
    @Test("lists built-in and custom systems, then renames the custom one")
    func listsAndRenamesSystems() throws {
        let test = try makeTestDatabase()
        let store = GradeSchemesStore(repos: test.repos)
        #expect(store.defaultSystemId == defaultGradeSystemID)
        #expect(store.systems.contains { $0.id == defaultGradeSystemID && $0.isBuiltin })

        let custom = try store.createCustomSystem(name: "My Scale", labels: ["K1", "K2", "K3"])
        #expect(custom.isBuiltin == false)
        #expect(store.systems.contains { $0.id == custom.id && !$0.isBuiltin })

        let levels = try store.levels(forSystem: custom.id)
        #expect(levels.map(\.label) == ["K1", "K2", "K3"])
        #expect(levels.map(\.rankOrder) == [0, 1, 2])

        let renamed = try store.rename(id: custom.id, name: "Home Wall")
        #expect(renamed.name == "Home Wall")
        #expect(store.systems.first { $0.id == custom.id }?.name == "Home Wall")
    }

    @Test("deleting a scheme in use surfaces the climb count")
    func deleteInUseSurfacesCount() throws {
        let test = try makeTestDatabase()
        let store = GradeSchemesStore(repos: test.repos)
        let gym = try seedGym(test.repos)
        let custom = try store.createCustomSystem(name: "Circuit", labels: ["C1", "C2"])
        let level = try store.levels(forSystem: custom.id)[0]
        for name in ["One", "Two"] {
            _ = try test.repos.climbs.create(
                CreateClimbInput(
                    gymId: gym.id,
                    name: name,
                    gradeSystemId: custom.id,
                    gradeLevelId: level.id
                )
            )
        }

        let error = #expect(throws: DomainValidationError.self) {
            try store.delete(id: custom.id)
        }
        #expect(error?.code == "grade_system_in_use")
        #expect(error?.message.contains("2 climbs") == true)
        #expect(store.systems.contains { $0.id == custom.id })
    }

    @Test("built-in schemes cannot be renamed or deleted")
    func builtinSchemesProtected() throws {
        let test = try makeTestDatabase()
        let store = GradeSchemesStore(repos: test.repos)

        let deleteError = #expect(throws: DomainValidationError.self) {
            try store.delete(id: defaultGradeSystemID)
        }
        #expect(deleteError?.code == "cannot_delete_builtin_scheme")

        let renameError = #expect(throws: DomainValidationError.self) {
            try store.rename(id: defaultGradeSystemID, name: "Renamed")
        }
        #expect(renameError?.code == "grade_system_not_found")
        #expect(renameError?.message == "Built-in schemes cannot be renamed.")
        #expect(store.systems.contains { $0.id == defaultGradeSystemID && $0.isBuiltin })
    }

    @Test("setDefault persists the default scheme for a fresh store")
    func setDefaultPersists() throws {
        let test = try makeTestDatabase()
        let store = GradeSchemesStore(repos: test.repos)
        let custom = try store.createCustomSystem(name: "Custom", labels: ["1", "2"])

        try store.setDefault(id: custom.id)
        #expect(store.defaultSystemId == custom.id)

        let fresh = GradeSchemesStore(repos: test.repos)
        #expect(fresh.defaultSystemId == custom.id)
        #expect(try test.repos.settings.getJSON(key: settingsKeyDefaultGradeSystem, as: String.self) == custom.id)

        let missing = #expect(throws: DomainValidationError.self) {
            try store.setDefault(id: "missing-system")
        }
        #expect(missing?.code == "grade_system_not_found")
        #expect(store.defaultSystemId == custom.id)
    }
}
