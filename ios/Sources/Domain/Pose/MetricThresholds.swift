import Foundation

/// Tunable constants for the Tier A metrics.
///
/// Every number here is a hypothesis until the P0 corpus exists, which is why they live in one
/// versioned struct rather than scattered through the maths. An analysis stores the version it was
/// produced with, so a threshold change makes old analyses visibly stale instead of silently
/// incomparable (docs/decisions.md, 2026-10-21 Phase 5 record, part 7).
public struct MetricThresholds: Codable, Equatable, Sendable {
    /// Bumped whenever a value below changes in a way that would move a result.
    public var version: Int = 2

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

    // Tier B, pose only. Every value here is a hypothesis until P0; a dyno is a fast hand
    // movement, not proof the hand left a hold (docs/decisions.md, 2026-10-22 P6 record).

    /// Hand speed that counts as a throw, in body heights per second. A real dyno hand moves at
    /// roughly one to two body heights per second, so this sits just above ordinary reaching.
    public var dynoMinimumHandSpeed: Double = 1.8
    /// Travel the hand must make across the throw, in body heights.
    public var dynoMinimumDisplacement: Double = 0.5
    /// Half window around a hand speed peak used to measure that travel.
    public var dynoWindowMs: Int = 500
    /// Minimum spacing between two reported dynos.
    public var dynoDebounceMs: Int = 800

    /// How far both ankles must rise toward the hips, in body heights.
    public var cutFeetMinimumRise: Double = 0.25
    /// Window within which the rise must happen.
    public var cutFeetWindowMs: Int = 700
    /// Body rise allowed over the same window, so a high step is not read as cut feet.
    public var cutFeetMaximumBodyRise: Double = 0.2
    /// Minimum spacing between two reported cut feet events.
    public var cutFeetDebounceMs: Int = 1200

    /// Stillness inside the attempt that counts as a rest.
    public var restMinimumMs: Int = 2000

    public init() {}
}
