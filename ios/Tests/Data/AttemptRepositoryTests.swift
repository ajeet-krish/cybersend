import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain

// Attempt repository tests (US-12): logAttempt is the canonical transaction with attempt_no
// computation, flash eligibility, and fall hold validation.

@Suite("AttemptRepository")
struct AttemptRepositoryTests {
    private struct Fixture {
        let gymId: String
        let sessionId: String
        let climbId: String
        let holds: [String]
    }

    private func makeFixture(_ test: TestDatabase) throws -> Fixture {
        let (gymId, climbId) = try seedGymAndClimb(test.repos)
        let session = try test.repos.sessions.create(CreateSessionInput(gymId: gymId))
        let holds = try (0..<3).map { index in
            try test.repos.holds.create(
                CreateHoldInput(climbId: climbId, xNorm: Double(index) * 0.25, yNorm: 0.5, role: .start)
            )
        }
        return Fixture(gymId: gymId, sessionId: session.id, climbId: climbId, holds: holds.map(\.id))
    }

    @Test("computes attempt_no per (session, climb) starting at 1")
    func computesAttemptNumbers() throws {
        let test = try makeTestDatabase()
        let fixture = try makeFixture(test)

        let first = try test.repos.attempts.logAttempt(
            LogAttemptInput(sessionId: fixture.sessionId, climbId: fixture.climbId, outcome: .project)
        )
        #expect(first.attempt.attemptNo == 1)
        #expect(first.warnings.isEmpty)

        let second = try test.repos.attempts.logAttempt(
            LogAttemptInput(sessionId: fixture.sessionId, climbId: fixture.climbId, outcome: .fail)
        )
        #expect(second.attempt.attemptNo == 2)

        // Another climb in the same session restarts at 1.
        let secondClimb = try test.repos.climbs.create(CreateClimbInput(gymId: fixture.gymId, name: "Other climb"))
        let otherClimbAttempt = try test.repos.attempts.logAttempt(
            LogAttemptInput(sessionId: fixture.sessionId, climbId: secondClimb.id, outcome: .project)
        )
        #expect(otherClimbAttempt.attempt.attemptNo == 1)
    }

    @Test("a flash after the first attempt is rejected")
    func flashRequiresFirstAttempt() throws {
        let test = try makeTestDatabase()
        let fixture = try makeFixture(test)
        _ = try test.repos.attempts.logAttempt(
            LogAttemptInput(sessionId: fixture.sessionId, climbId: fixture.climbId, outcome: .project)
        )

        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.attempts.logAttempt(
                LogAttemptInput(sessionId: fixture.sessionId, climbId: fixture.climbId, outcome: .flash)
            )
        }
        #expect(error?.code == "flash_requires_first_attempt")
        #expect(try test.repos.attempts.countByClimb(climbId: fixture.climbId) == 1)
    }

    @Test("a fall hold from another climb is rejected")
    func fallHoldFromAnotherClimbRejected() throws {
        let test = try makeTestDatabase()
        let fixture = try makeFixture(test)
        let otherClimb = try test.repos.climbs.create(CreateClimbInput(gymId: try test.repos.gyms.create(CreateGymInput(name: "Gym")).id))
        let foreignHold = try test.repos.holds.create(
            CreateHoldInput(climbId: otherClimb.id, xNorm: 0.5, yNorm: 0.5)
        )

        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.attempts.logAttempt(
                LogAttemptInput(
                    sessionId: fixture.sessionId,
                    climbId: fixture.climbId,
                    outcome: .fail,
                    fallOnHoldId: foreignHold.id
                )
            )
        }
        #expect(error?.code == "fall_hold_not_on_climb")
        #expect(try test.repos.attempts.countByClimb(climbId: fixture.climbId) == 0)
    }

    @Test("flash and send clear a provided fall hold with a warning")
    func sendClearsFallHoldWithWarning() throws {
        let test = try makeTestDatabase()
        let fixture = try makeFixture(test)

        let result = try test.repos.attempts.logAttempt(
            LogAttemptInput(
                sessionId: fixture.sessionId,
                climbId: fixture.climbId,
                outcome: .send,
                fallOnHoldId: fixture.holds[0]
            )
        )
        #expect(result.attempt.fallOnHoldId == nil)
        #expect(result.warnings == [warningOutcomeRecordsNoFallHold])
    }

    @Test("project and fail keep the fall hold")
    func projectKeepsFallHold() throws {
        let test = try makeTestDatabase()
        let fixture = try makeFixture(test)

        let result = try test.repos.attempts.logAttempt(
            LogAttemptInput(
                sessionId: fixture.sessionId,
                climbId: fixture.climbId,
                outcome: .project,
                fallOnHoldId: fixture.holds[1]
            )
        )
        #expect(result.attempt.fallOnHoldId == fixture.holds[1])
        #expect(result.warnings.isEmpty)
    }

    @Test("unknown session or climb is rejected")
    func unknownReferencesRejected() throws {
        let test = try makeTestDatabase()
        let fixture = try makeFixture(test)

        let sessionError = #expect(throws: DomainValidationError.self) {
            try test.repos.attempts.logAttempt(
                LogAttemptInput(sessionId: "missing", climbId: fixture.climbId, outcome: .fail)
            )
        }
        #expect(sessionError?.code == "session_not_found")

        let climbError = #expect(throws: DomainValidationError.self) {
            try test.repos.attempts.logAttempt(
                LogAttemptInput(sessionId: fixture.sessionId, climbId: "missing", outcome: .fail)
            )
        }
        #expect(climbError?.code == "climb_not_found")
    }

    @Test("updateAttempt re-validates outcome and fall hold")
    func updateRevalidates() throws {
        let test = try makeTestDatabase()
        let fixture = try makeFixture(test)
        let logged = try test.repos.attempts.logAttempt(
            LogAttemptInput(
                sessionId: fixture.sessionId,
                climbId: fixture.climbId,
                outcome: .fail,
                fallOnHoldId: fixture.holds[0]
            )
        )

        // Clearing the fall hold works.
        let cleared = try test.repos.attempts.updateAttempt(
            id: logged.attempt.id,
            patch: UpdateAttemptPatch(fallOnHoldId: .set(nil))
        )
        #expect(cleared.fallOnHoldId == nil)

        // Moving to send keeps attempt_no and clears a fall hold with the same rule.
        let upgraded = try test.repos.attempts.updateAttempt(
            id: logged.attempt.id,
            patch: UpdateAttemptPatch(outcome: .set(.send))
        )
        #expect(upgraded.outcome == .send)
        #expect(upgraded.attemptNo == logged.attempt.attemptNo)

        // A fall hold outside the climb stays rejected on update.
        let otherClimb = try test.repos.climbs.create(
            CreateClimbInput(gymId: try test.repos.gyms.create(CreateGymInput(name: "Other")).id)
        )
        let foreignHold = try test.repos.holds.create(CreateHoldInput(climbId: otherClimb.id, xNorm: 0.2, yNorm: 0.2))
        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.attempts.updateAttempt(
                id: logged.attempt.id,
                patch: UpdateAttemptPatch(fallOnHoldId: .set(foreignHold.id))
            )
        }
        #expect(error?.code == "fall_hold_not_on_climb")

        let missingError = #expect(throws: DomainValidationError.self) {
            try test.repos.attempts.updateAttempt(id: "missing", patch: UpdateAttemptPatch(notes: .set("x")))
        }
        #expect(missingError?.code == "attempt_not_found")
    }

    @Test("lists by session and by climb in attempted_at order")
    func listsBySessionAndClimb() throws {
        let test = try makeTestDatabase()
        let fixture = try makeFixture(test)
        _ = try test.repos.attempts.logAttempt(
            LogAttemptInput(sessionId: fixture.sessionId, climbId: fixture.climbId, outcome: .project, attemptedAt: "2026-10-19T10:00:00Z")
        )
        _ = try test.repos.attempts.logAttempt(
            LogAttemptInput(sessionId: fixture.sessionId, climbId: fixture.climbId, outcome: .fail, attemptedAt: "2026-10-19T11:00:00Z")
        )

        let bySession = try test.repos.attempts.listBySession(sessionId: fixture.sessionId)
        #expect(bySession.map(\.attemptNo) == [1, 2])
        let byClimb = try test.repos.attempts.listByClimb(climbId: fixture.climbId)
        #expect(byClimb.count == 2)
        #expect(try test.repos.attempts.countByClimb(climbId: fixture.climbId) == 2)

        try test.repos.attempts.delete(id: bySession[0].id)
        #expect(try test.repos.attempts.countByClimb(climbId: fixture.climbId) == 1)
    }

    @Test("attempted_at defaults to now and is stored per requirements section 2")
    func attemptedAtDefaultsToNow() throws {
        let test = try makeTestDatabase()
        let fixture = try makeFixture(test)
        let before = nowISO8601()
        let result = try test.repos.attempts.logAttempt(
            LogAttemptInput(sessionId: fixture.sessionId, climbId: fixture.climbId, outcome: .project)
        )
        #expect(result.attempt.attemptedAt >= before)
        let stored = try test.repos.attempts.get(id: result.attempt.id)
        #expect(stored?.attemptedAt == result.attempt.attemptedAt)
    }
}
