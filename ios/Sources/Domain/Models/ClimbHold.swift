import Foundation

/// Climb hold membership (US-20): one row per (climb, hold) link with an optional beta
/// sequence. holds.climb_id stays the origin climb (photo and lifecycle association);
/// membership and beta order live in climb_holds, so unlinking deletes join rows only
/// and never touches the hold or its attempts (docs/decisions.md "2026-10-20, Phase 2
/// (M3): climb_holds join table via Migration 002, export payload version 2").
public struct ClimbHold: Codable, Equatable, Sendable {
    public let climbId: String
    public let holdId: String
    public var sequence: Int?
    public let createdAt: String

    /// Membership is keyed by the (climb, hold) pair, so the pair doubles as the
    /// SwiftUI identity.
    public var id: String { "\(climbId):\(holdId)" }

    public init(climbId: String, holdId: String, sequence: Int? = nil, createdAt: String) {
        self.climbId = climbId
        self.holdId = holdId
        self.sequence = sequence
        self.createdAt = createdAt
    }
}
