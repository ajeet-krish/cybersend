import Foundation

/// Attempt outcome enum (port of src/domain/models/attempt.ts). Outcome is a single enum
/// column, never a status flag (requirements section 2).
public enum AttemptOutcome: String, Codable, CaseIterable, Sendable {
    case flash
    case send
    case project
    case fail
}

public let attemptOutcomes: [AttemptOutcome] = [.flash, .send, .project, .fail]

public func isAttemptOutcome(_ value: String) -> Bool {
    AttemptOutcome(rawValue: value) != nil
}

/// Attempt entity. attemptedAt is the moment the attempt happened (requirements section 2;
/// the old schema.sql stored it in created_at). fallOnHoldId is the requirements name for the
/// old fellOnHoldId column (schema reconciliation, 2026-10-19).
public struct Attempt: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sessionId: String
    public let climbId: String
    public var attemptNo: Int
    public var outcome: AttemptOutcome
    public var fallOnHoldId: String?
    public var videoId: String?
    public var notes: String?
    public var attemptedAt: String

    public init(
        id: String,
        sessionId: String,
        climbId: String,
        attemptNo: Int,
        outcome: AttemptOutcome,
        fallOnHoldId: String? = nil,
        videoId: String? = nil,
        notes: String? = nil,
        attemptedAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.climbId = climbId
        self.attemptNo = attemptNo
        self.outcome = outcome
        self.fallOnHoldId = fallOnHoldId
        self.videoId = videoId
        self.notes = notes
        self.attemptedAt = attemptedAt
    }
}
