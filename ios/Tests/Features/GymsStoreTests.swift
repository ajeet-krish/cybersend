import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Gyms management store tests (M2): create, rename, archive with refresh after each write,
// name validation, and the walls subtable query.

@Suite("GymsStore")
@MainActor
struct GymsStoreTests {
    @Test("creates, renames, and archives gyms with refresh after every write")
    func createRenameArchive() throws {
        let test = try makeTestDatabase()
        let store = GymsStore(repos: test.repos)
        #expect(store.gyms.isEmpty)

        let gym = try store.createGym(name: "Boulder Garden")
        #expect(store.gyms.map(\.id) == [gym.id])
        #expect(store.activeGyms.count == 1)

        let renamed = try store.rename(id: gym.id, name: "Boulder Garden North")
        #expect(renamed.name == "Boulder Garden North")
        #expect(store.gyms[0].name == "Boulder Garden North")

        _ = try store.setArchived(id: gym.id, archived: true)
        #expect(store.gyms.count == 1)
        #expect(store.activeGyms.isEmpty)

        _ = try store.setArchived(id: gym.id, archived: false)
        #expect(store.activeGyms.map(\.id) == [gym.id])
    }

    @Test("rejects blank gym names and unknown ids")
    func rejectsBlankNamesAndUnknownIds() throws {
        let test = try makeTestDatabase()
        let store = GymsStore(repos: test.repos)

        let blankCreate = #expect(throws: DomainValidationError.self) {
            try store.createGym(name: "   ")
        }
        #expect(blankCreate?.code == "gym_name_required")
        #expect(store.gyms.isEmpty)

        let gym = try store.createGym(name: "Gym")
        let blankRename = #expect(throws: DomainValidationError.self) {
            try store.rename(id: gym.id, name: "")
        }
        #expect(blankRename?.code == "gym_name_required")

        let unknownRename = #expect(throws: DomainValidationError.self) {
            try store.rename(id: "missing-gym", name: "Renamed")
        }
        #expect(unknownRename?.code == "gym_not_found")
        #expect(store.gyms.map(\.id) == [gym.id])
    }

    @Test("lists the gym walls through the gym aggregate")
    func listsWalls() throws {
        let test = try makeTestDatabase()
        let store = GymsStore(repos: test.repos)
        let gym = try store.createGym(name: "Gym")
        _ = try test.repos.gyms.createWall(
            CreateWallInput(gymId: gym.id, name: "Slab", angleDeg: 15, angleLabel: "Slab 15")
        )

        let walls = try store.walls(forGym: gym.id)
        #expect(walls.count == 1)
        #expect(walls[0].name == "Slab")
        #expect(walls[0].angleDeg == 15)
        #expect(try store.walls(forGym: "missing-gym").isEmpty)
    }
}
