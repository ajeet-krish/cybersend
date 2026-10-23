import Foundation

/// A progress curve expressed as a fraction of the attempt, so two clips of different lengths can
/// be drawn on one axis.
public struct NormalizedProgressPoint: Codable, Equatable, Sendable {
    /// 0 at the attempt start, 1 at the attempt end.
    public var progress: Double
    /// Height above the clip's lowest body centroid, in body heights.
    public var height: Double

    public init(progress: Double, height: Double) {
        self.progress = progress
        self.height = height
    }
}

/// One clip's comparable numbers. Everything is relative and body normalized; nothing here is a
/// force, a metre, or an absolute velocity.
public struct ComparisonSide: Equatable, Sendable {
    public var label: String
    public var durationMs: Int
    public var highestPoint: Double
    public var fallCount: Int
    /// Where the first fall happened, as a fraction of the attempt. Nil when there was no fall.
    public var fallProgress: Double?
    public var dynoCount: Int
    public var cutFeetCount: Int
    public var restSeconds: Double
    public var peakSpeed: Double?
    public var smoothness: Double?
    public var pathEfficiency: Double?
    public var quality: Double
    public var cameraClass: CameraStabilityClass
    /// Resampled onto `ClipComparison.curveResolution + 1` points from progress 0 to 1.
    public var curve: [NormalizedProgressPoint]
    /// Only carried when both clips allow a spatial read.
    public var hesitation: HesitationMap?

    public init(
        label: String,
        durationMs: Int,
        highestPoint: Double,
        fallCount: Int,
        fallProgress: Double? = nil,
        dynoCount: Int,
        cutFeetCount: Int,
        restSeconds: Double,
        peakSpeed: Double? = nil,
        smoothness: Double? = nil,
        pathEfficiency: Double? = nil,
        quality: Double,
        cameraClass: CameraStabilityClass,
        curve: [NormalizedProgressPoint] = [],
        hesitation: HesitationMap? = nil
    ) {
        self.label = label
        self.durationMs = durationMs
        self.highestPoint = highestPoint
        self.fallCount = fallCount
        self.fallProgress = fallProgress
        self.dynoCount = dynoCount
        self.cutFeetCount = cutFeetCount
        self.restSeconds = restSeconds
        self.peakSpeed = peakSpeed
        self.smoothness = smoothness
        self.pathEfficiency = pathEfficiency
        self.quality = quality
        self.cameraClass = cameraClass
        self.curve = curve
        self.hesitation = hesitation
    }
}

/// Two clips compared on metrics only.
///
/// There is no pixel level overlay of two clips. Handheld footage has no shared coordinate frame,
/// and even two fixed camera clips can differ in distance and angle, so the honest comparison is
/// the numbers plus the normalized progress curve (docs/decisions.md, 2026-10-21 Phase 5 record).
/// Spatial claims are limited to a per clip hesitation map and are only carried when both clips
/// were filmed from a fixed camera.
public struct ClipComparison: Equatable, Sendable {
    /// Points per normalized curve, plus the end point.
    public static let curveResolution = 50

    public var left: ComparisonSide
    public var right: ComparisonSide
    /// True only when both clips are stationary, which is the only case where a spatial read of
    /// the two hesitation maps is meaningful at all.
    public var spatialOverlayAllowed: Bool
    public var notes: [String]

    public enum Gate: Equatable, Sendable {
        case allowed(ClipComparison)
        case refused(String)
    }

    /// Compares two analysed clips, or explains why it will not.
    public static func compare(
        left: (label: String, metrics: TierAMetrics),
        right: (label: String, metrics: TierAMetrics)
    ) -> Gate {
        guard left.metrics.cameraClass.supportsComparison else {
            return .refused("\(left.label) was filmed handheld, so its numbers cannot be compared with another clip.")
        }
        guard right.metrics.cameraClass.supportsComparison else {
            return .refused("\(right.label) was filmed handheld, so its numbers cannot be compared with another clip.")
        }

        let spatial = left.metrics.cameraClass.supportsSpatialOverlay
            && right.metrics.cameraClass.supportsSpatialOverlay
        var notes: [String] = []
        if !spatial {
            notes.append("At least one clip was filmed nearly still rather than fixed, so the hesitation maps are not compared.")
        }
        notes.append("Heights and speeds are relative to each climber's body, not to the wall.")

        var leftSide = side(label: left.label, metrics: left.metrics)
        var rightSide = side(label: right.label, metrics: right.metrics)
        if !spatial {
            leftSide.hesitation = nil
            rightSide.hesitation = nil
        }

        return .allowed(ClipComparison(
            left: leftSide,
            right: rightSide,
            spatialOverlayAllowed: spatial,
            notes: notes
        ))
    }

    static func side(label: String, metrics: TierAMetrics) -> ComparisonSide {
        ComparisonSide(
            label: label,
            durationMs: metrics.attemptWindow.durationMs,
            highestPoint: metrics.highestPoint?.value ?? 0,
            fallCount: metrics.fallEvents.count,
            fallProgress: firstFallProgress(metrics),
            dynoCount: metrics.dynoEvents.count,
            cutFeetCount: metrics.cutFeetEvents.count,
            restSeconds: metrics.restEvents.reduce(0) { total, event in
                total + Double(max(0, (event.endMs ?? event.startMs) - event.startMs)) / 1000
            },
            peakSpeed: metrics.peakSpeed,
            smoothness: metrics.smoothness,
            pathEfficiency: metrics.pathEfficiency,
            quality: metrics.quality,
            cameraClass: metrics.cameraClass,
            curve: normalizedCurve(metrics),
            hesitation: metrics.hesitation
        )
    }

    /// Where the first fall sits inside the attempt, as a fraction of its duration. Comparing the
    /// fall point rather than the fall time is what makes a long attempt and a short one legible
    /// side by side.
    public static func firstFallProgress(_ metrics: TierAMetrics) -> Double? {
        guard let fall = metrics.fallEvents.min(by: { $0.startMs < $1.startMs }) else {
            return nil
        }
        let window = metrics.attemptWindow
        let duration = max(1, window.durationMs)
        let progress = Double(fall.startMs - window.startMs) / Double(duration)
        return min(1, max(0, progress))
    }

    /// The progress curve mapped onto attempt progress, resampled onto a fixed grid so two clips
    /// of different lengths share an x axis.
    public static func normalizedCurve(_ metrics: TierAMetrics) -> [NormalizedProgressPoint] {
        let window = metrics.attemptWindow
        let duration = max(1, window.durationMs)
        let samples = metrics.progress
            .filter { $0.tMs >= window.startMs && $0.tMs <= window.endMs }
            .map { sample -> (p: Double, v: Double) in
                let p = Double(sample.tMs - window.startMs) / Double(duration)
                return (min(1, max(0, p)), sample.value)
            }
        guard !samples.isEmpty else { return [] }

        return (0...curveResolution).map { step in
            let target = Double(step) / Double(curveResolution)
            return NormalizedProgressPoint(
                progress: target,
                height: interpolate(samples, at: target)
            )
        }
    }

    static func interpolate(_ samples: [(p: Double, v: Double)], at target: Double) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        if target <= first.p { return first.v }
        if target >= last.p { return last.v }
        for index in 1..<samples.count where samples[index].p >= target {
            let a = samples[index - 1]
            let b = samples[index]
            let span = b.p - a.p
            let weight = span > 0 ? (target - a.p) / span : 0
            return a.v + (b.v - a.v) * weight
        }
        return last.v
    }
}
