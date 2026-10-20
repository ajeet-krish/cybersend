import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain

// Hold repository tests: normalized coordinates validated at the domain boundary, roles and
// color families stored per the reconciled schema, ordinal ordering.

@Suite("HoldRepository")
struct HoldRepositoryTests {
    @Test("creates a hold with the default radius and manual source")
    func createsHoldWithDefaults() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)

        let hold = try test.repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 0.3, yNorm: 0.7))
        #expect(hold.radiusNorm == 0.02)
        #expect(hold.source == .manual)
        #expect(hold.role == nil)
        #expect(try test.repos.holds.get(id: hold.id) == hold)
    }

    @Test("rejects out of range coordinates before any write")
    func rejectsInvalidCoordinates() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)

        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 1.5, yNorm: 0.5))
        }
        #expect(error?.code == "hold_x_out_of_range")
        #expect(try test.repos.holds.idsForClimb(climbId: climbId).isEmpty)
    }

    @Test("stores role and color_family (US-19, schema reconciliation)")
    func storesRoleAndColorFamily() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)

        let hold = try test.repos.holds.create(
            CreateHoldInput(climbId: climbId, xNorm: 0.2, yNorm: 0.4, role: .start, colorFamily: "blue", ordinal: 0)
        )
        #expect(hold.role == .start)
        #expect(hold.colorFamily == "blue")
        #expect(hold.ordinal == 0)
    }

    @Test("lists by climb with nil ordinals last")
    func listsOrdinalsLast() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)

        let first = try test.repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 0.1, yNorm: 0.1, ordinal: 1))
        let unordered = try test.repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 0.2, yNorm: 0.2))
        let second = try test.repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 0.3, yNorm: 0.3, ordinal: 2))

        let listed = try test.repos.holds.listByClimb(climbId: climbId)
        #expect(listed.map(\.id) == [first.id, second.id, unordered.id])
    }

    @Test("updates position, role, and color through a patch")
    func updatesThroughPatch() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)
        let hold = try test.repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 0.1, yNorm: 0.1))

        let moved = try test.repos.holds.update(
            id: hold.id,
            patch: UpdateHoldPatch(xNorm: .set(0.5), yNorm: .set(0.6), role: .set(.top), colorFamily: .set("red"))
        )
        #expect(moved.xNorm == 0.5)
        #expect(moved.yNorm == 0.6)
        #expect(moved.role == .top)
        #expect(moved.colorFamily == "red")

        let invalid = #expect(throws: DomainValidationError.self) {
            try test.repos.holds.update(id: hold.id, patch: UpdateHoldPatch(xNorm: .set(-1)))
        }
        #expect(invalid?.code == "hold_x_out_of_range")

        let missing = #expect(throws: DomainValidationError.self) {
            try test.repos.holds.update(id: "missing", patch: UpdateHoldPatch(xNorm: .set(0.5)))
        }
        #expect(missing?.code == "hold_not_found")
    }

    @Test("deletes a single hold and all holds for a climb")
    func deletesHolds() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)
        let a = try test.repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 0.1, yNorm: 0.1))
        _ = try test.repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 0.2, yNorm: 0.2))

        try test.repos.holds.delete(id: a.id)
        #expect(try test.repos.holds.idsForClimb(climbId: climbId).count == 1)

        try test.repos.holds.deleteByClimb(climbId: climbId)
        #expect(try test.repos.holds.idsForClimb(climbId: climbId).isEmpty)
    }
}
