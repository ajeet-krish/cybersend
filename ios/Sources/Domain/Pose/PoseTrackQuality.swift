import Foundation

/// Quality summary for one analysed track. This is the value the review UI shows when it needs to
/// explain why a clip supports fewer metrics than the user expected, and it is the gate the
/// metrics layer uses before reporting anything.
public struct PoseTrackQuality: Codable, Equatable, Sendable {
    /// Average per frame coverage across the clip.
    public var averageCoverage: Double
    /// Fraction of analysed frames with no usable core joints at all.
    public var emptyFrameFraction: Double
    /// Longest continuous stretch with no usable frame.
    public var longestGapMs: Int
    /// Fraction of samples that were interpolated rather than observed.
    public var interpolatedFraction: Double
    /// Whether the clip passes the minimum bar for any metric at all.
    public var isUsableForMetrics: Bool

    public init(
        averageCoverage: Double,
        emptyFrameFraction: Double,
        longestGapMs: Int,
        interpolatedFraction: Double
    ) {
        self.averageCoverage = averageCoverage
        self.emptyFrameFraction = emptyFrameFraction
        self.longestGapMs = longestGapMs
        self.interpolatedFraction = interpolatedFraction
        self.isUsableForMetrics = averageCoverage >= PoseTrackQuality.minimumAverageCoverage
            && emptyFrameFraction <= PoseTrackQuality.maximumEmptyFrameFraction
            && longestGapMs <= PoseTrackQuality.maximumGapMs
    }

    public static let minimumAverageCoverage: Double = 0.6
    public static let maximumEmptyFrameFraction: Double = 0.2
    public static let maximumGapMs: Int = 1500

    /// Convenience for the common case of measuring a finished track.
    public static func measure(_ track: PoseTrack) -> PoseTrackQuality {
        let frames = track.frames
        guard !frames.isEmpty else {
            return PoseTrackQuality(
                averageCoverage: 0,
                emptyFrameFraction: 1,
                longestGapMs: 0,
                interpolatedFraction: 0
            )
        }

        let averageCoverage = frames.reduce(0.0) { $0 + $1.coverage } / Double(frames.count)
        let emptyCount = frames.reduce(into: 0) { count, frame in
            if frame.coverage == 0 { count += 1 }
        }

        var longestGap = 0
        var gapStartMs: Int?
        for frame in frames {
            if frame.isUsable {
                if let start = gapStartMs {
                    longestGap = max(longestGap, frame.tMs - start)
                    gapStartMs = nil
                }
            } else if gapStartMs == nil {
                gapStartMs = frame.tMs
            }
        }
        if let start = gapStartMs, let last = frames.last {
            longestGap = max(longestGap, last.tMs - start)
        }

        let sampleCount = frames.reduce(0) { $0 + $1.joints.count }
        let interpolatedCount = frames.reduce(0) { partial, frame in
            partial + frame.joints.values.reduce(0) { $0 + ($1.isInterpolated ? 1 : 0) }
        }

        return PoseTrackQuality(
            averageCoverage: averageCoverage,
            emptyFrameFraction: Double(emptyCount) / Double(frames.count),
            longestGapMs: longestGap,
            interpolatedFraction: sampleCount == 0 ? 0 : Double(interpolatedCount) / Double(sampleCount)
        )
    }
}
