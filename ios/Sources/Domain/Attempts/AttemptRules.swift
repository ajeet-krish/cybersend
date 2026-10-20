import Foundation

// Outcome rules for logging attempts (port of src/domain/attempts/rules.ts). The repository
// computes the next attempt number and the climb's hold ids, then this module validates the
// outcome against them (US-12).

public struct AttemptInput: Equatable, Sendable {
    public let outcome: AttemptOutcome
    public let fallOnHoldId: String?
    public let notes: String?
    public let videoId: String?

    public init(outcome: AttemptOutcome, fallOnHoldId: String? = nil, notes: String? = nil, videoId: String? = nil) {
        self.outcome = outcome
        self.fallOnHoldId = fallOnHoldId
        self.notes = notes
        self.videoId = videoId
    }
}

public struct AttemptRuleContext: Equatable, Sendable {
    /// The attempt number the repository will assign (next per session and climb).
    public let attemptNo: Int
    /// Hold ids that belong to the attempt's climb.
    public let climbHoldIds: [String]

    public init(attemptNo: Int, climbHoldIds: [String]) {
        self.attemptNo = attemptNo
        self.climbHoldIds = climbHoldIds
    }
}

public struct AttemptValidation: Equatable, Sendable {
    /// Normalized fall hold. flash and send record nil by rule; a provided value yields a
    /// warning instead of silently disappearing (requirements edge case: outcome contradiction).
    public let fallOnHoldId: String?
    public let warnings: [String]

    public init(fallOnHoldId: String?, warnings: [String]) {
        self.fallOnHoldId = fallOnHoldId
        self.warnings = warnings
    }
}

public let warningOutcomeRecordsNoFallHold = "outcome_records_no_fall_hold"

public func validateAttempt(input: AttemptInput, context: AttemptRuleContext) throws -> AttemptValidation {
    guard context.attemptNo >= 1 else {
        throw DomainValidationError("invalid_attempt_no", "Attempt number must be a positive integer.")
    }
    if input.outcome == .flash && context.attemptNo != 1 {
        throw DomainValidationError(
            "flash_requires_first_attempt",
            "A flash means the climb was sent on the first attempt of this session. Record later sends as send."
        )
    }

    if let fallOnHoldId = input.fallOnHoldId, !context.climbHoldIds.contains(fallOnHoldId) {
        throw DomainValidationError(
            "fall_hold_not_on_climb",
            "The selected fall hold does not belong to this climb."
        )
    }

    var warnings: [String] = []
    var fallOnHoldId = input.fallOnHoldId
    if input.outcome == .flash || input.outcome == .send {
        if fallOnHoldId != nil {
            warnings.append(warningOutcomeRecordsNoFallHold)
            fallOnHoldId = nil
        }
    }
    return AttemptValidation(fallOnHoldId: fallOnHoldId, warnings: warnings)
}
