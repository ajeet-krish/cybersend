import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain

// Climb hold membership (US-20): linking shares a hold across climbs without touching
// the hold or its attempts, unlinking deletes join rows only, sequence ordering drives
// listByClimb, and holds.climb_id stays the origin climb.

@Suite("ClimbHold membership")
struct ClimbHoldRepositoryTests {
    @Test("creating a hold links it to its origin climb with the ordinal as sequence")
    func createLinksOriginMembership() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)
        let hold = try test.repos.holds.create(
            CreateHoldInput(climbId: climbId, xNorm: 0.1, yNorm: 0.1, ordinal: 3)
        )

        #expect(try test.repos.holds.idsLinkedToClimb(climbId: climbId) == [hold.id])
        #expect(try test.repos.holds.linkedClimbIds(holdId: hold.id) == [climbId])
        #expect(try test.repos.holds.listByClimb(climbId: climbId).map(\.id) == [hold.id])
    }

    @Test("linking shares a hold across climbs; unlinking preserves the hold and attempts")
    func linkUnlinkPreservesHoldAndAttempts() throws {
        let test = try makeTestDatabase()
        let (gymId, climbA) = try seedGymAndClimb(test.repos)
        let climbB = try test.repos.climbs.create(CreateClimbInput(gymId: gymId, name: "Shared beta"))
        let hold = try test.repos.holds.create(CreateHoldInput(climbId: climbA, xNorm: 0.4, yNorm: 0.4))
        let session = try test.repos.sessions.create(CreateSessionInput(gymId: gymId))
        let result = try test.repos.attempts.logAttempt(
            LogAttemptInput(sessionId: session.id, climbId: climbA, outcome: .project, fallOnHoldId: hold.id)
        )
        let attempt = result.attempt

        let link = try test.repos.holds.linkHold(climbId: climbB.id, holdId: hold.id, sequence: 1)
        #expect(link.climbId == climbB.id)
        #expect(link.holdId == hold.id)
        #expect(link.sequence == 1)
        #expect(try test.repos.holds.listByClimb(climbId: climbB.id).map(\.id) == [hold.id])
        #expect(Set(try test.repos.holds.linkedClimbIds(holdId: hold.id)) == Set([climbA, climbB.id]))

        // Unlinking deletes the join row only: the hold, its origin climb, and the
        // attempt's fall hold reference all survive (US-20.4).
        try test.repos.holds.unlinkHold(climbId: climbB.id, holdId: hold.id)
        #expect(try test.repos.holds.listByClimb(climbId: climbB.id).isEmpty)
        #expect(try test.repos.holds.get(id: hold.id) != nil)
        #expect(try test.repos.holds.listByClimb(climbId: climbA).map(\.id) == [hold.id])
        #expect(try test.repos.attempts.get(id: attempt.id)?.fallOnHoldId == hold.id)
    }

    @Test("listByClimb orders by sequence then created_at with nil sequences last")
    func sequenceOrdering() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)
        let holdC = try test.repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 0.3, yNorm: 0.3))
        let holdA = try test.repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 0.1, yNorm: 0.1))
        let holdB = try test.repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 0.2, yNorm: 0.2))

        _ = try test.repos.holds.setSequence(climbId: climbId, holdId: holdA.id, sequence: 1)
        _ = try test.repos.holds.setSequence(climbId: climbId, holdId: holdB.id, sequence: 2)
        // holdC keeps the nil sequence it was created with and sorts last.

        #expect(try test.repos.holds.listByClimb(climbId: climbId).map(\.id) == [holdA.id, holdB.id, holdC.id])
        #expect(try test.repos.holds.idsLinkedToClimb(climbId: climbId) == [holdA.id, holdB.id, holdC.id])

        // Reordering through setSequence reshuffles the beta.
        _ = try test.repos.holds.setSequence(climbId: climbId, holdId: holdA.id, sequence: 5)
        #expect(try test.repos.holds.listByClimb(climbId: climbId).map(\.id) == [holdB.id, holdA.id, holdC.id])
    }

    @Test("listByClimb is membership, listOwnedByClimb is ownership")
    func membershipVersusOwnership() throws {
        let test = try makeTestDatabase()
        let (gymId, climbA) = try seedGymAndClimb(test.repos)
        let climbB = try test.repos.climbs.create(CreateClimbInput(gymId: gymId, name: "Borrower"))
        let shared = try test.repos.holds.create(CreateHoldInput(climbId: climbA, xNorm: 0.2, yNorm: 0.2))
        let ownedOnly = try test.repos.holds.create(CreateHoldInput(climbId: climbA, xNorm: 0.8, yNorm: 0.8))
        _ = try test.repos.holds.linkHold(climbId: climbB.id, holdId: shared.id, sequence: nil)

        // Climb B sees the shared hold through membership but owns nothing.
        #expect(try test.repos.holds.listByClimb(climbId: climbB.id).map(\.id) == [shared.id])
        #expect(try test.repos.holds.listOwnedByClimb(climbId: climbB.id).isEmpty)

        // Climb A owns both and still lists both through membership.
        #expect(Set(try test.repos.holds.listOwnedByClimb(climbId: climbA).map(\.id)) == Set([shared.id, ownedOnly.id]))
        #expect(Set(try test.repos.holds.listByClimb(climbId: climbA).map(\.id)) == Set([shared.id, ownedOnly.id]))
    }

    @Test("linking validates the climb and hold and relinking updates the sequence")
    func linkingValidatesAndRelinks() throws {
        let test = try makeTestDatabase()
        let (gymId, climbA) = try seedGymAndClimb(test.repos)
        let climbB = try test.repos.climbs.create(CreateClimbInput(gymId: gymId))
        let hold = try test.repos.holds.create(CreateHoldInput(climbId: climbA, xNorm: 0.5, yNorm: 0.5))

        let missingHold = #expect(throws: DomainValidationError.self) {
            try test.repos.holds.linkHold(climbId: climbB.id, holdId: "missing", sequence: nil)
        }
        #expect(missingHold?.code == "hold_not_found")

        let missingClimb = #expect(throws: DomainValidationError.self) {
            try test.repos.holds.linkHold(climbId: "missing", holdId: hold.id, sequence: nil)
        }
        #expect(missingClimb?.code == "climb_not_found")

        // Relinking keeps one membership row and refreshes the sequence.
        _ = try test.repos.holds.linkHold(climbId: climbB.id, holdId: hold.id, sequence: 1)
        let relinked = try test.repos.holds.linkHold(climbId: climbB.id, holdId: hold.id, sequence: 4)
        #expect(relinked.sequence == 4)
        #expect(try test.repos.holds.idsLinkedToClimb(climbId: climbB.id) == [hold.id])

        // Sequence edits require a link.
        let unlinked = #expect(throws: DomainValidationError.self) {
            try test.repos.holds.setSequence(climbId: "missing", holdId: hold.id, sequence: 1)
        }
        #expect(unlinked?.code == "climb_hold_not_found")
    }

    @Test("deleting a hold cascades its membership rows")
    func deleteCascadesMembership() throws {
        let test = try makeTestDatabase()
        let (gymId, climbA) = try seedGymAndClimb(test.repos)
        let climbB = try test.repos.climbs.create(CreateClimbInput(gymId: gymId))
        let hold = try test.repos.holds.create(CreateHoldInput(climbId: climbA, xNorm: 0.5, yNorm: 0.5))
        _ = try test.repos.holds.linkHold(climbId: climbB.id, holdId: hold.id, sequence: nil)

        try test.repos.holds.delete(id: hold.id)
        #expect(try test.repos.holds.idsLinkedToClimb(climbId: climbA).isEmpty)
        #expect(try test.repos.holds.idsLinkedToClimb(climbId: climbB.id).isEmpty)
        #expect(try test.repos.holds.listByClimb(climbId: climbB.id).isEmpty)
    }
}
