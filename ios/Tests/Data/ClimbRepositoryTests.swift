import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain

// Climb repository tests (US-10, US-26): normalized grade references, angle validation,
// archive visibility, delete blocked when attempts exist.

@Suite("ClimbRepository")
struct ClimbRepositoryTests {
    @Test("creates a climb with the default V scale grade system")
    func createsClimbWithDefaults() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))
        let climb = try test.repos.climbs.create(CreateClimbInput(gymId: gym.id, name: "  Blue V4  "))

        #expect(climb.name == "Blue V4")
        #expect(climb.gradeSystemId == "v_scale")
        #expect(climb.gradeLevelId == nil)
        #expect(climb.isActive)
        #expect(!climb.isArchived)
        #expect(try test.repos.climbs.get(id: climb.id) == climb)
    }

    @Test("a blank name becomes nil")
    func blankNameBecomesNil() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))
        let climb = try test.repos.climbs.create(CreateClimbInput(gymId: gym.id, name: "   "))
        #expect(climb.name == nil)
    }

    @Test("rejects a missing gym, invalid angles, and unknown grade levels")
    func rejectsInvalidInputs() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))

        let gymError = #expect(throws: DomainValidationError.self) {
            try test.repos.climbs.create(CreateClimbInput(gymId: "missing"))
        }
        #expect(gymError?.code == "gym_not_found")

        let angleError = #expect(throws: DomainValidationError.self) {
            try test.repos.climbs.create(CreateClimbInput(gymId: gym.id, angleDeg: 95))
        }
        #expect(angleError?.code == "climb_angle_out_of_range")

        let levelError = #expect(throws: DomainValidationError.self) {
            try test.repos.climbs.create(CreateClimbInput(gymId: gym.id, gradeSystemId: "v_scale", gradeLevelId: "v99"))
        }
        #expect(levelError?.code == "grade_level_not_in_scheme")

        let schemeError = #expect(throws: DomainValidationError.self) {
            try test.repos.climbs.create(CreateClimbInput(gymId: gym.id, gradeSystemId: "no_such", gradeLevelId: "x"))
        }
        #expect(schemeError?.code == "grade_system_not_found")
    }

    @Test("stores a (scheme, level) grade pair (US-9)")
    func storesGradePair() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))
        let climb = try test.repos.climbs.create(
            CreateClimbInput(gymId: gym.id, gradeSystemId: "font", gradeLevelId: "f6a_plus")
        )
        #expect(climb.gradeSystemId == "font")
        #expect(climb.gradeLevelId == "f6a_plus")
    }

    @Test("list hides archived and inactive climbs by default (US-10)")
    func listHidesArchivedAndInactive() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))
        let active = try test.repos.climbs.create(CreateClimbInput(gymId: gym.id, name: "Active"))
        let archived = try test.repos.climbs.create(CreateClimbInput(gymId: gym.id, name: "Archived"))
        let inactive = try test.repos.climbs.create(CreateClimbInput(gymId: gym.id, name: "Inactive"))
        _ = try test.repos.climbs.archive(id: archived.id)
        _ = try test.repos.climbs.setActive(id: inactive.id, active: false)

        let visible = try test.repos.climbs.list()
        #expect(visible.map(\.id) == [active.id])

        let all = try test.repos.climbs.list(options: ListClimbsOptions(includeArchived: true, includeInactive: true))
        #expect(Set(all.map(\.id)) == Set([active.id, archived.id, inactive.id]))
    }

    @Test("updates name and grade through a patch")
    func updatesThroughPatch() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))
        let climb = try test.repos.climbs.create(CreateClimbInput(gymId: gym.id, name: "Old"))

        let updated = try test.repos.climbs.update(
            id: climb.id,
            patch: UpdateClimbPatch(name: .set("New"), gradeLevelId: .set("v6"), angleDeg: .set(30))
        )
        #expect(updated.name == "New")
        #expect(updated.gradeLevelId == "v6")
        #expect(updated.angleDeg == 30)
        #expect(updated.updatedAt >= climb.updatedAt)

        // .unchanged leaves fields alone.
        let untouched = try test.repos.climbs.update(id: climb.id, patch: UpdateClimbPatch())
        #expect(untouched.name == "New")
        #expect(untouched.angleDeg == 30)

        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.climbs.update(id: "missing", patch: UpdateClimbPatch(name: .set("x")))
        }
        #expect(error?.code == "climb_not_found")
    }

    @Test("deleting a climb with attempts is blocked; archive only (US-26)")
    func deleteBlockedWithAttempts() throws {
        let test = try makeTestDatabase()
        let (gymId, climbId) = try seedGymAndClimb(test.repos)
        let session = try test.repos.sessions.create(CreateSessionInput(gymId: gymId))
        _ = try test.repos.attempts.logAttempt(
            LogAttemptInput(sessionId: session.id, climbId: climbId, outcome: .project)
        )

        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.climbs.delete(id: climbId)
        }
        #expect(error?.message.contains("Archive it instead of deleting") ?? false)
        #expect(try test.repos.climbs.countAttempts(id: climbId) == 1)

        // Archiving still works and keeps the attempts.
        let archived = try test.repos.climbs.archive(id: climbId)
        #expect(archived.isArchived)
        #expect(try test.repos.attempts.countByClimb(climbId: climbId) == 1)
    }

    @Test("deleting a climb without attempts removes it")
    func deleteWithoutAttemptsWorks() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)
        try test.repos.climbs.delete(id: climbId)
        #expect(try test.repos.climbs.get(id: climbId) == nil)
    }
}
