import Foundation

/// Tunable constants for the Tier A metrics.
///
/// Every number here is a hypothesis until the P0 corpus exists, which is why they live in one
/// versioned struct rather than scattered through the maths. An analysis stores the version it was
/// produced with, so a threshold change makes old analyses visibly stale instead of silently
/// incomparable (docs/decisions.md, 2026-10-21 Phase 5 record, part 7).
public struct MetricThresholds: Codable, Equatable, Sendable {
    /// Bumped whenever a value below changes in a way that would move a result.
    public var version: Int = 1

    /// Uniform grid the track is resampled onto before any derivative is taken.
    public var analysisHz: Double = 30
    /// Resolution of the progress curve returned to the UI.
    public var progressHz: Double = 10
    /// Longest gap that may be filled by linear interpolation. Longer gaps stay missing.
    public var maximumInterpolationGapMs: Int = 250
    /// Minimum per frame coverage for a frame to contribute a centroid.
    public var minimumFrameCoverage: Double = 0.5

    /// Speed, in body heights per second, below which the climber counts as still.
    public var restSpeed: Double = 0.15
    /// Speed that marks the start of an attempt.
    public var startSpeed: Double = 0.35
    /// How long `startSpeed` must hold before the attempt starts.
    public var sustainedStartMs: Int = 300
    /// Stillness required before the first movement.
    public var minimumRestMs: Int = 1000

    /// Quiet time near the ground that ends an attempt when there is no fall.
    public var quietEndMs: Int = 800
    /// Height band, in body heights, that counts as near the ground.
    public var endHeightBand: Double = 0.35

    /// Downward travel that makes a fall.
    public var fallMinimumDrop: Double = 0.5
    /// Window within which that drop must happen.
    public var fallMaximumDropMs: Int = 1500
    /// Downward speed that must be reached during a fall, in body heights per second.
    public var fallMinimumDownSpeed: Double = 1.2
    /// Minimum spacing between two reported falls.
    public var fallDebounceMs: Int = 1500
    /// Lateral travel during the drop above which a fall is reported with lower confidence.
    public var fallHorizontalDriftSoftLimit: Double = 0.4

    /// Speed below which time is counted into the hesitation map.
    public var hesitationSpeed: Double = 0.15
    public var hesitationColumns: Int = 24
    public var hesitationRows: Int = 32

    /// Median low passed horizontal speed that separates the three camera classes.
    public var cameraStaticHorizontal: Double = 0.06
    public var cameraNearStaticHorizontal: Double = 0.18

    /// Path length below which smoothness is meaningless, in body heights.
    public var smoothnessMinimumPathLength: Double = 0.5

    public init() {}
}
