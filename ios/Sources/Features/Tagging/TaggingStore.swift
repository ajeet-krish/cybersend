import Combine
import CyberSendData
import CyberSendDomain
import Foundation

// Tagging store (M3, US-19): holds of one climb with selection and a bounded undo stack.
// Every edit is one repository write followed by a reload, and every edit records its
// inverse command so undo and redo replay exactly (docs/decisions.md, bounded undo
// stack in TaggingStore). Deleting a hold cascades its climb_holds membership rows, and
// undoing that delete restores the identical row (same id, timestamps, membership)
// through HoldRepository.createRestoring, so canvas identity and beta order survive.
// The 200 holds per photo budget (US-19.4) is plain data at this scale: the store never
// truncates or collapses holds and the reload always reflects every row.

@MainActor
public final class TaggingStore: ObservableObject {
    /// Holds linked to the climb, in beta order (repository order).
    @Published public private(set) var holds: [Hold] = []
    @Published public private(set) var selectedHoldId: String?
    @Published public private(set) var lastErrorMessage: String?

    /// The undo stack drops its oldest entry beyond this many commands, so memory stays
    /// bounded no matter how long a tagging session runs.
    public static let undoStackLimit = 50

    private let repos: Repositories
    private var climbId = ""
    private var undoStack: [TaggingCommand] = []
    private var redoStack: [TaggingCommand] = []

    public init(repos: Repositories) {
        self.repos = repos
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Loads the climb's holds and resets selection and both undo stacks (the stacks
    /// are per tagging session, not persisted).
    public func load(climbId: String) {
        self.climbId = climbId
        undoStack.removeAll()
        redoStack.removeAll()
        selectedHoldId = nil
        refresh()
    }

    /// Places a new hold at a normalized point. HoldRepository.create writes the hold
    /// and its origin membership rows in one transaction, so the hold is immediately
    /// part of the climb's set (US-20).
    @discardableResult
    public func addHold(
        xNorm: Double,
        yNorm: Double,
        radiusNorm: Double = defaultHoldRadiusNorm,
        role: HoldRole? = nil
    ) throws -> Hold {
        do {
            let hold = try repos.holds.create(CreateHoldInput(
                climbId: climbId,
                xNorm: xNorm,
                yNorm: yNorm,
                radiusNorm: radiusNorm,
                role: role
            ))
            record(.addHold(hold: hold))
            selectedHoldId = hold.id
            refresh()
            lastErrorMessage = nil
            return hold
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Drags a hold to a new normalized point. A move to the same point is a no-op and
    /// records no history entry.
    public func moveHold(id: String, xNorm: Double, yNorm: Double) throws {
        do {
            let hold = try requireHold(id: id)
            guard hold.xNorm != xNorm || hold.yNorm != yNorm else { return }
            _ = try repos.holds.update(id: id, patch: UpdateHoldPatch(xNorm: .set(xNorm), yNorm: .set(yNorm)))
            record(.moveHold(holdId: id, fromX: hold.xNorm, fromY: hold.yNorm, toX: xNorm, toY: yNorm))
            refresh()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Assigns or clears a hold role (US-19.1: editable at any time). Setting the role
    /// it already has is a no-op and records no history entry.
    public func setRole(id: String, role: HoldRole?) throws {
        do {
            let hold = try requireHold(id: id)
            guard hold.role != role else { return }
            _ = try repos.holds.update(id: id, patch: UpdateHoldPatch(role: .set(role)))
            record(.setRole(holdId: id, fromRole: hold.role, toRole: role))
            refresh()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Deletes a hold. The row delete cascades the climb_holds membership rows, and the
    /// snapshot the undo stack keeps can restore the exact row (US-19.2).
    public func deleteHold(id: String) throws {
        do {
            let hold = try requireHold(id: id)
            try repos.holds.delete(id: id)
            record(.deleteHold(hold: hold))
            if selectedHoldId == id {
                selectedHoldId = nil
            }
            refresh()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Applies the inverse of the most recent edit. A no-op when the stack is empty.
    public func undo() throws {
        guard let command = undoStack.popLast() else { return }
        do {
            try applyInverse(command)
            push(command, onto: &redoStack)
            refresh()
            lastErrorMessage = nil
        } catch {
            undoStack.append(command)
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Reapplies the most recent undone edit. A no-op when the redo stack is empty.
    public func redo() throws {
        guard let command = redoStack.popLast() else { return }
        do {
            try applyForward(command)
            push(command, onto: &undoStack)
            refresh()
            lastErrorMessage = nil
        } catch {
            redoStack.append(command)
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Internals

    /// One undoable edit. Commands carry the snapshot or coordinates that both the
    /// forward and the inverse application need, so replay never re-derives state.
    private enum TaggingCommand {
        case addHold(hold: Hold)
        case deleteHold(hold: Hold)
        case moveHold(holdId: String, fromX: Double, fromY: Double, toX: Double, toY: Double)
        case setRole(holdId: String, fromRole: HoldRole?, toRole: HoldRole?)
    }

    private func refresh() {
        holds = (try? repos.holds.listByClimb(climbId: climbId)) ?? []
    }

    private func requireHold(id: String) throws -> Hold {
        guard let hold = holds.first(where: { $0.id == id }) else {
            throw DomainValidationError("hold_not_found", "Hold not found.")
        }
        return hold
    }

    /// Records an edit on the undo stack (bounded, oldest entry dropped past the
    /// limit) and invalidates the redo stack: new edits and old redos never mix.
    private func record(_ command: TaggingCommand) {
        push(command, onto: &undoStack)
        redoStack.removeAll()
    }

    private func push(_ command: TaggingCommand, onto stack: inout [TaggingCommand]) {
        stack.append(command)
        if stack.count > Self.undoStackLimit {
            stack.removeFirst(stack.count - Self.undoStackLimit)
        }
    }

    private func applyInverse(_ command: TaggingCommand) throws {
        switch command {
        case .addHold(let hold):
            try repos.holds.delete(id: hold.id)
            if selectedHoldId == hold.id {
                selectedHoldId = nil
            }
        case .deleteHold(let hold):
            _ = try repos.holds.createRestoring(hold)
            selectedHoldId = hold.id
        case .moveHold(let holdId, let fromX, let fromY, _, _):
            _ = try repos.holds.update(id: holdId, patch: UpdateHoldPatch(xNorm: .set(fromX), yNorm: .set(fromY)))
        case .setRole(let holdId, let fromRole, _):
            _ = try repos.holds.update(id: holdId, patch: UpdateHoldPatch(role: .set(fromRole)))
        }
    }

    private func applyForward(_ command: TaggingCommand) throws {
        switch command {
        case .addHold(let hold):
            _ = try repos.holds.createRestoring(hold)
            selectedHoldId = hold.id
        case .deleteHold(let hold):
            try repos.holds.delete(id: hold.id)
            if selectedHoldId == hold.id {
                selectedHoldId = nil
            }
        case .moveHold(let holdId, _, _, let toX, let toY):
            _ = try repos.holds.update(id: holdId, patch: UpdateHoldPatch(xNorm: .set(toX), yNorm: .set(toY)))
        case .setRole(let holdId, _, let toRole):
            _ = try repos.holds.update(id: holdId, patch: UpdateHoldPatch(role: .set(toRole)))
        }
    }
}
