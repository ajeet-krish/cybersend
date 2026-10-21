import Combine
import CyberSendData
import CyberSendDomain
import Foundation

// Session detail and quick-log store (M2). One instance per open or closed session screen
// (port of the session screen state in app/session/[id].tsx): the session row, the session
// gym, quick-log climbs, attempts grouped per climb, and holds for the fall hold picker.
// Repositories are called synchronously on the main actor and every write is followed by
// refresh().

/// One row of the session attempt list: a climb plus this session's attempts for it (the
/// TypeScript screen's grouped Map<climbId, Attempt[]> entry, named for SwiftUI use).
public struct ClimbGroup: Equatable, Identifiable, Sendable {
    public var id: String { climb.id }
    public let climb: Climb
    public let attempts: [Attempt]

    public init(climb: Climb, attempts: [Attempt]) {
        self.climb = climb
        self.attempts = attempts
    }
}

@MainActor
public final class SessionDetailStore: ObservableObject {
    public let sessionId: String

    @Published public private(set) var session: Session?
    /// The session's gym, for the detail header (nil when the session is gone).
    @Published public private(set) var gym: Gym?
    /// Quick-log climbs of the session gym: active and not archived (US-10), matching the
    /// TypeScript screen's chip list.
    @Published public private(set) var climbs: [Climb] = []
    /// This session's attempts grouped per climb, ordered by first attempt.
    @Published public private(set) var groups: [ClimbGroup] = []
    /// Holds per climb id for the fall hold picker; populated for every climb in the
    /// session gym plus any attempt-only climb (usually empty until M3 tagging).
    @Published public private(set) var climbHolds: [String: [Hold]] = [:]
    /// The climb quick-log logs against (set from the chip row).
    @Published public private(set) var selectedClimbId: String?
    @Published public private(set) var lastErrorMessage: String?

    private let repos: Repositories

    public init(repos: Repositories, sessionId: String) {
        self.repos = repos
        self.sessionId = sessionId
        refresh()
    }

    /// The selected climb from the quick-log list or the attempt groups.
    public var selectedClimb: Climb? {
        if let climb = climbs.first(where: { $0.id == selectedClimbId }) {
            return climb
        }
        return groups.first { $0.climb.id == selectedClimbId }?.climb
    }

    /// Reloads the session, its gym, climbs, attempt groups, and climb holds.
    public func refresh() {
        do {
            session = try repos.sessions.get(id: sessionId)
            guard let session else {
                gym = nil
                climbs = []
                groups = []
                climbHolds = [:]
                selectedClimbId = nil
                lastErrorMessage = nil
                return
            }
            gym = try repos.gyms.get(id: session.gymId)
            let attempts = try repos.attempts.listBySession(sessionId: sessionId)
            climbs = try repos.climbs.list(options: ListClimbsOptions(gymId: session.gymId))
            groups = try groupAttempts(attempts)
            climbHolds = try loadClimbHolds()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Selects the climb quick-log logs against (nil clears the selection).
    public func selectClimb(_ climb: Climb?) {
        selectedClimbId = climb?.id
    }

    /// Selects a climb by id when the caller only carries the identifier.
    public func selectClimb(id: String?) {
        selectedClimbId = id
    }

    /// Logs one attempt for the selected climb (US-12) and returns the repository warnings,
    /// for example warningOutcomeRecordsNoFallHold when a send or flash carries a fall hold.
    /// Domain rules run inside the repository transaction: flash only on attempt 1, the fall
    /// hold must belong to the climb.
    @discardableResult
    public func logAttempt(outcome: AttemptOutcome, fallOnHoldId: String? = nil, rpe: Int? = nil) throws -> [String] {
        guard let climbId = selectedClimbId else {
            throw DomainValidationError("no_climb_selected", "Pick a climb first.")
        }
        let result = try repos.attempts.logAttempt(
            LogAttemptInput(
                sessionId: sessionId,
                climbId: climbId,
                outcome: outcome,
                fallOnHoldId: fallOnHoldId,
                rpe: rpe
            )
        )
        refresh()
        return result.warnings
    }

    /// Closes the session with a domain validated RPE (1 to 10, US-11.1) and notes. Nil rpe
    /// or notes clear the stored value, matching the TypeScript store, and closing an
    /// already closed session is a no-op that returns the stored row (US-11.3).
    @discardableResult
    public func closeSession(rpe: Int?, notes: String? = nil) throws -> Session {
        let validatedRPE = try validateRPE(rpe)
        let closed = try repos.sessions.close(
            id: sessionId,
            input: CloseSessionInput(rpe: .set(validatedRPE), notes: .set(notes))
        )
        refresh()
        return closed
    }

    /// Edits an attempt with patch semantics that keep the TypeScript three state
    /// distinction of src/data/repositories/attempt_repository.ts: .unchanged keeps the
    /// stored value (TypeScript undefined), .set(nil) clears it (TypeScript null), and
    /// .set(value) replaces it. Outcome and fall hold are revalidated against the domain
    /// rules exactly like a fresh log.
    @discardableResult
    public func updateAttempt(
        id: String,
        outcome: PatchValue<AttemptOutcome> = .unchanged,
        fallOnHoldId: PatchValue<String?> = .unchanged,
        notes: PatchValue<String?> = .unchanged,
        rpe: PatchValue<Int?> = .unchanged
    ) throws -> Attempt {
        let updated = try repos.attempts.updateAttempt(
            id: id,
            patch: UpdateAttemptPatch(outcome: outcome, fallOnHoldId: fallOnHoldId, notes: notes, rpe: rpe)
        )
        refresh()
        return updated
    }

    /// Deletes one attempt (the UI confirms first), then reloads.
    public func deleteAttempt(id: String) throws {
        try repos.attempts.delete(id: id)
        refresh()
    }

    /// Deletes the session; its attempts cascade with the foreign key. Confirmation is the
    /// screen's job, the store just deletes.
    public func deleteSession() throws {
        try repos.sessions.delete(id: sessionId)
        refresh()
    }

    // MARK: - Private

    /// Buckets the session's attempts (ordered by attempted_at, attempt_no) per climb and
    /// keeps first attempt order, resolving each climb, including attempt-only climbs that
    /// the quick-log list may exclude.
    private func groupAttempts(_ attempts: [Attempt]) throws -> [ClimbGroup] {
        var climbsById: [String: Climb] = [:]
        for climb in climbs {
            climbsById[climb.id] = climb
        }
        var order: [String] = []
        var bucket: [String: [Attempt]] = [:]
        for attempt in attempts {
            if bucket[attempt.climbId] == nil {
                order.append(attempt.climbId)
            }
            bucket[attempt.climbId, default: []].append(attempt)
            if climbsById[attempt.climbId] == nil, let climb = try repos.climbs.get(id: attempt.climbId) {
                climbsById[attempt.climbId] = climb
            }
        }
        return order.compactMap { climbId in
            guard let climb = climbsById[climbId] else { return nil }
            return ClimbGroup(climb: climb, attempts: bucket[climbId] ?? [])
        }
    }

    /// Loads holds for every quick-log climb and every attempt-only climb so the fall hold
    /// picker can read climbHolds[selectedClimbId] without an extra load.
    private func loadClimbHolds() throws -> [String: [Hold]] {
        var holdIds = Set(climbs.map(\.id))
        for group in groups {
            holdIds.insert(group.climb.id)
        }
        var result: [String: [Hold]] = [:]
        for climbId in holdIds {
            result[climbId] = try repos.holds.listByClimb(climbId: climbId)
        }
        return result
    }
}
