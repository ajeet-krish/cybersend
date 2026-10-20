import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Session detail store tests (M2): quick-log grouping, attempt warnings, the flash rule,
// idempotent close with domain RPE validation, patch semantics on update, and deletes with
// attempt cascade.

/// One open session at one gym with a single quick-loggable climb.
private struct SessionFixture {
    let test: TestDatabase
    let gym: Gym
    let climb: Climb
    let session: Session
}

private func makeSessionFixture() throws -> SessionFixture {
    let test = try makeTestDatabase()
    let gym = try seedGym(test.repos)
    let climb = try seedClimb(test.repos, gymId: gym.id)
    let session = try test.repos.sessions.create(CreateSessionInput(gymId: gym.id))
    return SessionFixture(test: test, gym: gym, climb: climb, session: session)
}

@Suite("SessionDetailStore")
@MainActor
struct SessionDetailStoreTests {
    @Test("groups quick logged attempts by climb")
    func groupsAttemptsByClimb() throws {
        let fixture = try makeSessionFixture()
        let store = SessionDetailStore(repos: fixture.test.repos, sessionId: fixture.session.id)
        store.selectClimb(fixture.climb)

        let warnings = try store.logAttempt(outcome: .send)

        #expect(warnings.isEmpty)
        #expect(store.session?.id == fixture.session.id)
        #expect(store.gym?.id == fixture.gym.id)
        #expect(store.climbs.map(\.id) == [fixture.climb.id])
        #expect(store.groups.count == 1)
        #expect(store.groups[0].climb.id == fixture.climb.id)
        #expect(store.groups[0].attempts.count == 1)
        #expect(store.groups[0].attempts[0].attemptNo == 1)
        #expect(store.groups[0].attempts[0].outcome == .send)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("logAttempt stores the outcome, returns warnings, and exposes holds")
    func logAttemptStoresWarningsAndHolds() throws {
        let fixture = try makeSessionFixture()
        let hold = try seedHold(fixture.test.repos, climbId: fixture.climb.id)
        let store = SessionDetailStore(repos: fixture.test.repos, sessionId: fixture.session.id)
        store.selectClimb(id: fixture.climb.id)

        // A send records no fall hold: the repository warns and clears the value (US-12).
        let warnings = try store.logAttempt(outcome: .send, fallOnHoldId: hold.id)

        #expect(warnings == [warningOutcomeRecordsNoFallHold])
        #expect(store.groups[0].attempts[0].outcome == .send)
        #expect(store.groups[0].attempts[0].fallOnHoldId == nil)
        #expect(store.climbHolds[fixture.climb.id]?.map(\.id) == [hold.id])
    }

    @Test("flash after the first attempt of the session is rejected")
    func flashAfterFirstAttemptRejected() throws {
        let fixture = try makeSessionFixture()
        let store = SessionDetailStore(repos: fixture.test.repos, sessionId: fixture.session.id)
        store.selectClimb(fixture.climb)
        _ = try store.logAttempt(outcome: .project)

        let error = #expect(throws: DomainValidationError.self) {
            try store.logAttempt(outcome: .flash)
        }
        #expect(error?.code == "flash_requires_first_attempt")
        #expect(store.groups[0].attempts.count == 1)

        // Later sends record as send, and the failed flash wrote nothing.
        _ = try store.logAttempt(outcome: .send)
        #expect(store.groups[0].attempts.count == 2)
        #expect(store.groups[0].attempts[1].attemptNo == 2)
        #expect(store.groups[0].attempts[1].outcome == .send)
    }

    @Test("closeSession validates RPE, stores notes, and is idempotent")
    func closeSessionIdempotent() throws {
        let fixture = try makeSessionFixture()
        let store = SessionDetailStore(repos: fixture.test.repos, sessionId: fixture.session.id)

        let closed = try store.closeSession(rpe: 7, notes: "pumped")
        #expect(closed.endedAt != nil)
        #expect(closed.rpe == 7)
        #expect(store.session?.endedAt == closed.endedAt)
        #expect(store.session?.rpe == 7)
        #expect(store.session?.notes == "pumped")

        // Closing again returns the stored row unchanged (US-11.3).
        let again = try store.closeSession(rpe: 3, notes: nil)
        #expect(again.rpe == 7)
        #expect(again.notes == "pumped")
        #expect(again.endedAt == closed.endedAt)
        #expect(store.session?.rpe == 7)
    }

    @Test("closeSession rejects RPE outside 1 to 10 and leaves the session open")
    func closeSessionRejectsInvalidRPE() throws {
        let fixture = try makeSessionFixture()
        let store = SessionDetailStore(repos: fixture.test.repos, sessionId: fixture.session.id)

        let low = #expect(throws: DomainValidationError.self) {
            try store.closeSession(rpe: 0)
        }
        #expect(low?.code == "rpe_out_of_range")

        let high = #expect(throws: DomainValidationError.self) {
            try store.closeSession(rpe: 11)
        }
        #expect(high?.code == "rpe_out_of_range")

        #expect(store.session?.endedAt == nil)
        #expect(try fixture.test.repos.sessions.getOpen()?.id == fixture.session.id)
    }

    @Test("updateAttempt keeps, sets, and clears fields with patch semantics")
    func updateAttemptPatchSemantics() throws {
        let fixture = try makeSessionFixture()
        let hold = try seedHold(fixture.test.repos, climbId: fixture.climb.id)
        let store = SessionDetailStore(repos: fixture.test.repos, sessionId: fixture.session.id)
        store.selectClimb(fixture.climb)
        _ = try store.logAttempt(outcome: .project)
        let attemptId = store.groups[0].attempts[0].id

        // .set replaces one field (TypeScript defined); the rest stay unchanged.
        let withNotes = try store.updateAttempt(id: attemptId, notes: .set("second go"))
        #expect(withNotes.notes == "second go")
        #expect(withNotes.outcome == .project)

        // Outcome and fall hold set together, validated against the climb's holds.
        let failed = try store.updateAttempt(
            id: attemptId,
            outcome: .set(.fail),
            fallOnHoldId: .set(hold.id)
        )
        #expect(failed.outcome == .fail)
        #expect(failed.fallOnHoldId == hold.id)

        // .unchanged keeps the stored fall hold (TypeScript undefined).
        let kept = try store.updateAttempt(id: attemptId, outcome: .set(.project))
        #expect(kept.outcome == .project)
        #expect(kept.fallOnHoldId == hold.id)

        // .set(nil) clears both fields (TypeScript null) and refresh reflects it.
        let cleared = try store.updateAttempt(
            id: attemptId,
            fallOnHoldId: .set(nil),
            notes: .set(nil)
        )
        #expect(cleared.fallOnHoldId == nil)
        #expect(cleared.notes == nil)
        #expect(store.groups[0].attempts[0].notes == nil)
        #expect(store.groups[0].attempts[0].fallOnHoldId == nil)
    }

    @Test("deleteAttempt removes the row and deleteSession cascades attempts")
    func deleteAttemptAndSession() throws {
        let fixture = try makeSessionFixture()
        let store = SessionDetailStore(repos: fixture.test.repos, sessionId: fixture.session.id)
        store.selectClimb(fixture.climb)
        _ = try store.logAttempt(outcome: .project)
        let attemptId = store.groups[0].attempts[0].id

        try store.deleteAttempt(id: attemptId)
        #expect(store.groups.isEmpty)
        #expect(try fixture.test.repos.attempts.listBySession(sessionId: fixture.session.id).isEmpty)

        _ = try store.logAttempt(outcome: .send)
        #expect(store.groups[0].attempts.count == 1)

        try store.deleteSession()
        #expect(store.session == nil)
        #expect(store.gym == nil)
        #expect(store.groups.isEmpty)
        #expect(store.climbs.isEmpty)
        #expect(try fixture.test.repos.sessions.get(id: fixture.session.id) == nil)
        #expect(try fixture.test.repos.attempts.listBySession(sessionId: fixture.session.id).isEmpty)
    }

    @Test("logAttempt needs a selected climb and a real session")
    func logAttemptGuards() throws {
        let fixture = try makeSessionFixture()
        let store = SessionDetailStore(repos: fixture.test.repos, sessionId: fixture.session.id)

        let noClimb = #expect(throws: DomainValidationError.self) {
            try store.logAttempt(outcome: .send)
        }
        #expect(noClimb?.code == "no_climb_selected")

        let missing = SessionDetailStore(repos: fixture.test.repos, sessionId: "missing-session")
        #expect(missing.session == nil)
        missing.selectClimb(id: fixture.climb.id)
        let notFound = #expect(throws: DomainValidationError.self) {
            try missing.logAttempt(outcome: .send)
        }
        #expect(notFound?.code == "session_not_found")
    }
}
