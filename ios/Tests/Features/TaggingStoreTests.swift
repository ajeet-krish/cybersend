import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Tagging store tests (M3, US-19 and US-20): hold placement with its mirrored
// membership row, drag and role edits, delete plus undo restoration of the exact row,
// the bounded 50 entry undo stack with redo invalidation, and the 200 holds per photo
// budget (US-19.4) without corruption.

@Suite("TaggingStore")
@MainActor
struct TaggingStoreTests {
    private func makeStore() throws -> (store: TaggingStore, repos: Repositories, climbId: String) {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)
        let store = TaggingStore(repos: test.repos)
        store.load(climbId: climbId)
        return (store, test.repos, climbId)
    }

    @Test("addHold writes the hold and its origin membership in one repository call")
    func addHoldCreatesMembership() throws {
        let (store, repos, climbId) = try makeStore()

        let hold = try store.addHold(xNorm: 0.25, yNorm: 0.75, role: .start)

        #expect(hold.xNorm == 0.25)
        #expect(hold.yNorm == 0.75)
        #expect(hold.role == .start)
        #expect(hold.source == .manual)
        #expect(store.holds.map(\.id) == [hold.id])
        #expect(store.selectedHoldId == hold.id)
        #expect(store.canUndo == true)
        // The membership row exists without a separate link call (US-20).
        #expect(try repos.holds.idsLinkedToClimb(climbId: climbId) == [hold.id])
        #expect(try repos.holds.get(id: hold.id) == hold)

        // Invalid coordinates are rejected before anything is written.
        let error = #expect(throws: DomainValidationError.self) {
            try store.addHold(xNorm: 2, yNorm: 0.5)
        }
        #expect(error?.code == "hold_x_out_of_range")
        #expect(store.holds.count == 1)
        #expect(store.lastErrorMessage != nil)
    }

    @Test("move, role, and delete edits persist and clear selection on delete")
    func editLifecycle() throws {
        let (store, repos, climbId) = try makeStore()
        let first = try store.addHold(xNorm: 0.2, yNorm: 0.2)
        let second = try store.addHold(xNorm: 0.8, yNorm: 0.8)

        try store.moveHold(id: first.id, xNorm: 0.3, yNorm: 0.35)
        #expect(store.holds.first { $0.id == first.id }?.xNorm == 0.3)
        #expect(try repos.holds.get(id: first.id)?.yNorm == 0.35)

        try store.setRole(id: second.id, role: .top)
        #expect(try repos.holds.get(id: second.id)?.role == .top)

        // A no-op move and a no-op role set change nothing and record no history.
        try store.moveHold(id: first.id, xNorm: 0.3, yNorm: 0.35)
        try store.setRole(id: second.id, role: .top)
        #expect(try repos.holds.get(id: first.id)?.xNorm == 0.3)

        try store.deleteHold(id: second.id)
        #expect(store.holds.map(\.id) == [first.id])
        #expect(store.selectedHoldId == nil, "the deleted selection clears")
        #expect(try repos.holds.get(id: second.id) == nil)
        // The cascade removed the membership row with the hold (US-20.4 keeps them in
        // step; unlink semantics are the repository's job).
        #expect(try repos.holds.idsLinkedToClimb(climbId: climbId) == [first.id])

        // An unknown id fails without disturbing state.
        let missing = #expect(throws: DomainValidationError.self) {
            try store.moveHold(id: "missing", xNorm: 0.5, yNorm: 0.5)
        }
        #expect(missing?.code == "hold_not_found")
        #expect(store.holds.count == 1)
    }

    @Test("undo and redo replay in order with exact identities, and new edits clear redo")
    func undoRedoOrder() throws {
        let (store, repos, climbId) = try makeStore()
        let first = try store.addHold(xNorm: 0.2, yNorm: 0.2, role: .start)
        let second = try store.addHold(xNorm: 0.8, yNorm: 0.8)
        try store.moveHold(id: first.id, xNorm: 0.4, yNorm: 0.45)
        try store.setRole(id: first.id, role: .top)

        // Undo in reverse: role, move, add second, add first.
        try store.undo()
        #expect(store.holds.first { $0.id == first.id }?.role == .start)
        try store.undo()
        #expect(store.holds.first { $0.id == first.id }?.xNorm == 0.2)
        try store.undo()
        #expect(store.holds.map(\.id) == [first.id])
        try store.undo()
        #expect(store.holds.isEmpty)
        #expect(store.canUndo == false)
        #expect(store.canRedo == true)

        // Redo replays forward with the same identities.
        try store.redo()
        #expect(store.holds.map(\.id) == [first.id])
        try store.redo()
        #expect(store.holds.map(\.id) == [first.id, second.id])
        try store.redo()
        #expect(store.holds.first { $0.id == first.id }?.xNorm == 0.4)
        try store.redo()
        #expect(store.holds.first { $0.id == first.id }?.role == .top)
        #expect(store.canRedo == false)

        // Delete and undo: the identical row (id, timestamps, membership) comes back.
        try store.deleteHold(id: second.id)
        try store.undo()
        #expect(store.holds.map(\.id) == [first.id, second.id])
        #expect(try repos.holds.get(id: second.id) == second)
        #expect(try repos.holds.idsLinkedToClimb(climbId: climbId) == [first.id, second.id])
        #expect(store.selectedHoldId == second.id, "undo restores the selection it cleared")

        // A new edit invalidates the redo stack.
        #expect(store.canRedo == true)
        _ = try store.addHold(xNorm: 0.6, yNorm: 0.6)
        #expect(store.canRedo == false)
    }

    @Test("the undo stack is bounded at 50 entries and drops the oldest")
    func boundedUndoStack() throws {
        let (store, _, _) = try makeStore()
        for index in 0 ..< 60 {
            let step = Double(index) + 1
            _ = try store.addHold(xNorm: step / 100, yNorm: step / 100)
        }
        #expect(store.holds.count == 60)

        var undos = 0
        while store.canUndo {
            try store.undo()
            undos += 1
        }
        #expect(undos == TaggingStore.undoStackLimit)
        #expect(store.holds.count == 60 - TaggingStore.undoStackLimit)
    }

    @Test("200 holds per photo survive edits and undo without corruption (US-19.4)")
    func twoHundredHolds() throws {
        let (store, repos, climbId) = try makeStore()

        for index in 0 ..< 200 {
            let x = Double(index % 20) / 20 + 0.01
            let y = Double(index / 20) / 10 + 0.05
            _ = try store.addHold(xNorm: x, yNorm: y)
        }
        #expect(store.holds.count == 200)
        #expect(Set(store.holds.map(\.id)).count == 200, "every id is distinct")
        #expect(try repos.holds.idsLinkedToClimb(climbId: climbId).count == 200)

        // Drag every hold to a fresh point and verify every position persisted.
        var expectedPositions: [String: (x: Double, y: Double)] = [:]
        for hold in store.holds {
            let newY = min(0.99, hold.yNorm + 0.001)
            try store.moveHold(id: hold.id, xNorm: hold.xNorm, yNorm: newY)
            expectedPositions[hold.id] = (x: hold.xNorm, y: newY)
        }
        let moved = try repos.holds.listByClimb(climbId: climbId)
        #expect(moved.count == 200)
        for hold in moved {
            let expected = try #require(expectedPositions[hold.id])
            #expect(hold.xNorm == expected.x, "hold \(hold.id) x persisted")
            #expect(hold.yNorm == expected.y, "hold \(hold.id) y persisted")
        }

        // Role edits round trip across the whole set.
        for (index, hold) in store.holds.enumerated() {
            let role: HoldRole = index % 3 == 0 ? .start : (index % 3 == 1 ? .intermediate : .top)
            try store.setRole(id: hold.id, role: role)
        }
        let roles = try repos.holds.listByClimb(climbId: climbId)
        #expect(roles.filter { $0.role == .start }.count == 67)
        #expect(roles.filter { $0.role == .intermediate }.count == 67)
        #expect(roles.filter { $0.role == .top }.count == 66)

        // Deletes and their undos restore the exact membership set.
        let victims = Array(store.holds.prefix(5))
        for victim in victims {
            try store.deleteHold(id: victim.id)
        }
        #expect(try repos.holds.idsLinkedToClimb(climbId: climbId).count == 195)
        for victim in victims {
            try store.undo()
        }
        #expect(try repos.holds.idsLinkedToClimb(climbId: climbId).count == 200)
        for victim in victims {
            #expect(try repos.holds.get(id: victim.id) == victim)
        }
    }
}
