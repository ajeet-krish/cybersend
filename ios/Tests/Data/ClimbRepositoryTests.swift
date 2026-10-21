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
            LogAttemptInput(sessionId: session.id, climbId: climbId, outcome: .fail)
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

    @Test("deleting a climb whose holds are shared with another climb is blocked (US-20)")
    func deleteBlockedWithSharedHolds() throws {
        let test = try makeTestDatabase()
        let (gymId, climbA) = try seedGymAndClimb(test.repos)
        let climbB = try test.repos.climbs.create(CreateClimbInput(gymId: gymId, name: "B"))
        let hold = try test.repos.holds.create(CreateHoldInput(climbId: climbA, xNorm: 0.4, yNorm: 0.4))
        _ = try test.repos.holds.linkHold(climbId: climbB.id, holdId: hold.id, sequence: 1)

        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.climbs.delete(id: climbA)
        }
        #expect(error?.code == "climb_has_shared_holds")
        #expect(try test.repos.climbs.get(id: climbA) != nil)

        // After unlinking, the delete goes through: no attempts, no shares left.
        try test.repos.holds.unlinkHold(climbId: climbB.id, holdId: hold.id)
        try test.repos.climbs.delete(id: climbA)
        #expect(try test.repos.climbs.get(id: climbA) == nil)
        #expect(try test.repos.holds.get(id: hold.id) == nil, "the owned hold cascades with its origin climb")
    }

    @Test("deleting a climb whose owned holds are attempt-referenced elsewhere is blocked")
    func deleteBlockedWithAttemptReferencedHolds() throws {
        let test = try makeTestDatabase()
        let (gymId, climbA) = try seedGymAndClimb(test.repos)
        let climbB = try test.repos.climbs.create(CreateClimbInput(gymId: gymId, name: "B"))
        let hold = try test.repos.holds.create(CreateHoldInput(climbId: climbA, xNorm: 0.4, yNorm: 0.4))
        _ = try test.repos.holds.linkHold(climbId: climbB.id, holdId: hold.id, sequence: 1)
        let session = try test.repos.sessions.create(CreateSessionInput(gymId: gymId))
        // The attempt is logged on climb B and falls on the hold climb A owns; deleting
        // climb A would SET NULL the fall hold and lose the fall data.
        _ = try test.repos.attempts.logAttempt(
            LogAttemptInput(sessionId: session.id, climbId: climbB.id, outcome: .fail, fallOnHoldId: hold.id)
        )
        // Unlinking the membership does not clear the attempt's fall hold reference,
        // so the hold stays attempt-referenced while no longer shared.
        try test.repos.holds.unlinkHold(climbId: climbB.id, holdId: hold.id)

        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.climbs.delete(id: climbA)
        }
        #expect(error?.code == "climb_holds_in_attempts")
        #expect(try test.repos.climbs.get(id: climbA) != nil)

        // The climb with the attempt on it stays blocked by the attempts guard itself.
        let attemptError = #expect(throws: DomainValidationError.self) {
            try test.repos.climbs.delete(id: climbB.id)
        }
        #expect(attemptError?.code == "climb_has_attempts")
    }
}
