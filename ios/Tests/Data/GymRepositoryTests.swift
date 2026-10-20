import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain

// Gym repository tests (US-8, port of src/data/repositories/__tests__/gym_repository.test.ts):
// create, rename, archive visibility, duplicate names, walls.

@Suite("GymRepository")
struct GymRepositoryTests {
    @Test("creates a gym and lists it as not archived")
    func createsGym() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Boulder Garden"))

        #expect(gym.name == "Boulder Garden")
        #expect(!gym.isArchived)
        let listed = try test.repos.gyms.list()
        #expect(listed.map(\.id) == [gym.id])
        #expect(try test.repos.gyms.get(id: gym.id) == gym)
    }

    @Test("rejects an empty name")
    func rejectsEmptyName() throws {
        let test = try makeTestDatabase()
        #expect(throws: DomainValidationError.self) {
            try test.repos.gyms.create(CreateGymInput(name: "   "))
        }
    }

    @Test("allows duplicate names, disambiguated by id (US-8.3)")
    func allowsDuplicateNames() throws {
        let test = try makeTestDatabase()
        let first = try test.repos.gyms.create(CreateGymInput(name: "Momentum"))
        let second = try test.repos.gyms.create(CreateGymInput(name: "Momentum"))
        #expect(first.id != second.id)
        #expect(try test.repos.gyms.list().count == 2)
    }

    @Test("renames a gym and rejects unknown ids")
    func renamesGym() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Old name"))
        let renamed = try test.repos.gyms.rename(id: gym.id, name: "New name")
        #expect(renamed.name == "New name")
        #expect(renamed.updatedAt >= gym.updatedAt)

        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.gyms.rename(id: "missing", name: "x")
        }
        #expect(error?.message.contains("Gym not found") ?? false)
    }

    @Test("archived gyms are hidden from the default list but visible with includeArchived (US-8.4)")
    func archivedGymsHiddenByDefault() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Seasonal"))
        _ = try test.repos.gyms.archive(id: gym.id)

        #expect(try test.repos.gyms.list().isEmpty)
        let all = try test.repos.gyms.list(includeArchived: true)
        #expect(all.map(\.id) == [gym.id])
        #expect(all.first?.isArchived == true)

        _ = try test.repos.gyms.unarchive(id: gym.id)
        #expect(try test.repos.gyms.list().count == 1)
    }

    @Test("walls belong to the gym aggregate and require a valid gym (FK enforced)")
    func wallsBelongToGymAggregate() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Wall Town"))
        let wall = try test.repos.gyms.createWall(CreateWallInput(gymId: gym.id, name: "Slab", angleDeg: 20))

        #expect(wall.angleDeg == 20)
        let walls = try test.repos.gyms.listWalls(gymId: gym.id)
        #expect(walls.map(\.id) == [wall.id])

        #expect(throws: Error.self) {
            try test.repos.gyms.createWall(CreateWallInput(gymId: "missing", name: "x"))
        }
        let angleError = #expect(throws: DomainValidationError.self) {
            try test.repos.gyms.createWall(CreateWallInput(gymId: gym.id, angleDeg: 120))
        }
        #expect(angleError?.message.contains("between 0 and 90") ?? false)

        try test.repos.gyms.setWallActive(id: wall.id, active: false)
        #expect(try test.repos.gyms.listWalls(gymId: gym.id).isEmpty)
        #expect(try test.repos.gyms.listWalls(gymId: gym.id, includeInactive: true).count == 1)
    }
}
