import Foundation

// Grade normalization seam (requirements US-27 to US-30). rasch_lite fitting, the translator,
// and the persisted grade_norm_params load and store land in M4; this module freezes the data
// the engine will consume plus the data-sufficiency constants so Domain, Data, and Features can
// compile against one shape before then.

/// One climb's attempt sample, aggregated by the repository and fed to the engine.
public struct GradeNormalizationSample: Equatable, Sendable {
    public let climbId: String
    public let gymId: String
    public let attemptCount: Int
    public let successCount: Int
    /// The climb's ordered position in its scheme (grade_levels.rank_order), when graded.
    public let rankOrder: Int?

    public init(climbId: String, gymId: String, attemptCount: Int, successCount: Int, rankOrder: Int?) {
        self.climbId = climbId
        self.gymId = gymId
        self.attemptCount = attemptCount
        self.successCount = successCount
        self.rankOrder = rankOrder
    }
}

public enum GradeNormalization {
    /// US-30 thresholds: the feature stays hidden below 30 attempts and 2 gyms.
    public static let minimumAttemptCount = 30
    public static let minimumGymCount = 2

    public static func isDataSufficient(attemptCount: Int, gymCount: Int) -> Bool {
        attemptCount >= minimumAttemptCount && gymCount >= minimumGymCount
    }
}

/// The M4 engine contract. Implementations must be pure functions of their samples so stats
/// screens can recompute synchronously (US-27.2).
public protocol GradeNormalizationEngine: Sendable {
    var algoVersion: String { get }
    /// Returns the normalized difficulty for one climb, or nil when the sample is insufficient.
    func normalizedDifficulty(climbId: String, samples: [GradeNormalizationSample]) -> Double?
}
