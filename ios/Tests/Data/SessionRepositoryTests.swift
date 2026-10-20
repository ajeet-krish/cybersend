import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain

// Session repository tests (US-11): one open session at a time, idempotent close, RPE
// validation, history with attempt counts.

@Suite("SessionRepository")
struct SessionRepositoryTests {
    @Test("creates an open session and rejects a missing gym")
    func createsOpenSession() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))

        // The gym check fires before the open session check only when no session is open.
        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.sessions.create(CreateSessionInput(gymId: "missing"))
        }
        #expect(error?.code == "gym_not_found")

        let session = try test.repos.sessions.create(CreateSessionInput(gymId: gym.id))
        #expect(isSessionOpen(session))
        #expect(session.rpe == nil)
        #expect(try test.repos.sessions.getOpen()?.id == session.id)
    }

    @Test("at most one open session at a time (US-11.2)")
    func oneOpenSessionAtATime() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))
        _ = try test.repos.sessions.create(CreateSessionInput(gymId: gym.id))

        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.sessions.create(CreateSessionInput(gymId: gym.id))
        }
        #expect(error?.code == "open_session_exists")
    }

    @Test("closing is idempotent and validates RPE (US-11.3)")
    func closeIsIdempotent() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))
        let session = try test.repos.sessions.create(CreateSessionInput(gymId: gym.id))

        let closed = try test.repos.sessions.close(
            id: session.id,
            input: CloseSessionInput(rpe: .set(7), notes: .set("pumped"))
        )
        #expect(closed.endedAt != nil)
        #expect(closed.rpe == 7)
        #expect(closed.notes == "pumped")

        // Closing again returns the session unchanged, even with different input.
        let again = try test.repos.sessions.close(
            id: session.id,
            input: CloseSessionInput(rpe: .set(3))
        )
        #expect(again.rpe == 7)
        #expect(again.endedAt == closed.endedAt)
    }

    @Test("RPE outside 1 to 10 is rejected on close and update")
    func rejectsInvalidRPE() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))
        let session = try test.repos.sessions.create(CreateSessionInput(gymId: gym.id))

        let closeError = #expect(throws: DomainValidationError.self) {
            try test.repos.sessions.close(id: session.id, input: CloseSessionInput(rpe: .set(11)))
        }
        #expect(closeError?.code == "rpe_out_of_range")

        let updateError = #expect(throws: DomainValidationError.self) {
            try test.repos.sessions.update(id: session.id, patch: UpdateSessionPatch(rpe: .set(0)))
        }
        #expect(updateError?.code == "rpe_out_of_range")

        // The session stayed open: the failed close rolled back.
        #expect(try test.repos.sessions.getOpen()?.id == session.id)
    }

    @Test("multiple sessions per day are allowed once the first is closed")
    func multipleSessionsPerDayAllowed() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))
        let first = try test.repos.sessions.create(CreateSessionInput(gymId: gym.id, startedAt: "2026-10-19T09:00:00Z"))
        _ = try test.repos.sessions.close(id: first.id)
        let second = try test.repos.sessions.create(CreateSessionInput(gymId: gym.id, startedAt: "2026-10-19T18:00:00Z"))
        #expect(second.id != first.id)
    }

    @Test("history lists sessions reverse chronologically with attempt counts (US-22.1)")
    func historyWithAttemptCounts() throws {
        let test = try makeTestDatabase()
        let (gymId, climbId) = try seedGymAndClimb(test.repos)
        let morning = try test.repos.sessions.create(CreateSessionInput(gymId: gymId, startedAt: "2026-10-19T09:00:00Z"))
        _ = try test.repos.sessions.close(id: morning.id)
        let evening = try test.repos.sessions.create(CreateSessionInput(gymId: gymId, startedAt: "2026-10-19T18:00:00Z"))

        _ = try test.repos.attempts.logAttempt(LogAttemptInput(sessionId: morning.id, climbId: climbId, outcome: .project))
        _ = try test.repos.attempts.logAttempt(LogAttemptInput(sessionId: morning.id, climbId: climbId, outcome: .send))
        _ = try test.repos.attempts.logAttempt(LogAttemptInput(sessionId: evening.id, climbId: climbId, outcome: .fail))

        let history = try test.repos.sessions.list()
        #expect(history.map(\.session.id) == [evening.id, morning.id])
        #expect(history.map(\.attemptCount) == [1, 2])
    }

    @Test("delete removes the session")
    func deleteRemovesSession() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))
        let session = try test.repos.sessions.create(CreateSessionInput(gymId: gym.id))
        try test.repos.sessions.delete(id: session.id)
        #expect(try test.repos.sessions.get(id: session.id) == nil)
    }

    @Test("closing an unknown session is rejected")
    func closeUnknownSessionRejected() throws {
        let test = try makeTestDatabase()
        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.sessions.close(id: "missing")
        }
        #expect(error?.code == "session_not_found")
    }
}
