import Foundation

/// Session entity and RPE rules (port of src/domain/models/session.ts). RPE is session level,
/// integer 1 to 10 (requirements section 2).
public struct Session: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let gymId: String
    public var startedAt: String
    public var endedAt: String?
    public var rpe: Int?
    public var notes: String?
    public let createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        gymId: String,
        startedAt: String,
        endedAt: String? = nil,
        rpe: Int? = nil,
        notes: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.gymId = gymId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.rpe = rpe
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Reverse-chronological history row with the attempt count (US-22.1).
public struct SessionSummary: Codable, Equatable, Sendable {
    public let session: Session
    public let attemptCount: Int

    public init(session: Session, attemptCount: Int) {
        self.session = session
        self.attemptCount = attemptCount
    }
}

public let minRPE = 1
public let maxRPE = 10

public func isSessionOpen(_ session: Session) -> Bool {
    session.endedAt == nil
}

/// Validates session RPE regardless of source (US-11.1, edge case RPE out of range).
/// Swift Int is always integral, so the integer check from the TypeScript spec is implied.
public func validateRPE(_ rpe: Int?) throws -> Int? {
    guard let rpe else { return nil }
    if rpe < minRPE || rpe > maxRPE {
        throw DomainValidationError(
            "rpe_out_of_range",
            "RPE must be an integer from \(minRPE) to \(maxRPE) (got \(rpe))."
        )
    }
    return rpe
}
