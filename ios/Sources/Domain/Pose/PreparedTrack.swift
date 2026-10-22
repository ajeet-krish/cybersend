import Foundation

/// Estimated body height for a clip, in normalized image units.
public struct BodyScale: Codable, Equatable, Sendable {
    /// Median of the per frame body height estimates.
    public let medianBodyHeight: Double
    /// Interquartile spread divided by the median. High spread means the estimate is unstable,
    /// usually because the climber turned sideways and foreshortened the torso.
    public let relativeSpread: Double
    /// True when the estimate came from head to ankle spans and the spread was small.
    public let isReliable: Bool
    /// True when the estimate fell back to a torso based approximation.
    public let usedFallback: Bool

    public init(
        medianBodyHeight: Double,
        relativeSpread: Double,
        isReliable: Bool,
        usedFallback: Bool
    ) {
        self.medianBodyHeight = medianBodyHeight
        self.relativeSpread = relativeSpread
        self.isReliable = isReliable
        self.usedFallback = usedFallback
    }
}

/// A track resampled onto a uniform grid and expressed in body heights.
///
/// Everything downstream works on this, never on raw joints, so the maths has one time base, one
/// smoothing pass, and one scale. Coordinates stay normalized in x, and `height` is body heights
/// above the lowest centroid in the clip, so 0 is the bottom of the movement.
public struct PreparedTrack: Sendable, Equatable {
    public let samplingHz: Double
    public let startMs: Int
    public let endMs: Int
    public let bodyScale: BodyScale
    /// Smoothed centroid x, normalized image space.
    public let x: [Double]
    /// Smoothed centroid y, normalized image space, top left origin.
    public let y: [Double]
    /// Body heights above the clip's lowest centroid.
    public let height: [Double]
    /// Speed magnitude, body heights per second.
    public let speed: [Double]
    /// Horizontal speed, body heights per second.
    public let horizontalSpeed: [Double]
    /// Vertical speed, body heights per second, positive upward.
    public let verticalSpeed: [Double]
    public let coverage: Double
    /// Notes for the review screen, such as a truncated analysis segment.
    public let warnings: [String]

    public var sampleCount: Int { x.count }

    public func timeMs(at index: Int) -> Int {
        startMs + Int((Double(index) / samplingHz * 1000).rounded())
    }

    public func index(atOrBefore tMs: Int) -> Int {
        let offset = Double(tMs - startMs) / 1000 * samplingHz
        return min(max(0, Int(offset.rounded())), max(0, sampleCount - 1))
    }
}

/// Builds a `PreparedTrack` from a raw pose track.
public enum TrackPreparation {
    public static func prepare(
        _ track: PoseTrack,
        thresholds: MetricThresholds = MetricThresholds()
    ) -> PreparedTrack? {
        guard track.frames.count >= 3 else { return nil }

        var warnings: [String] = []
        guard let scale = bodyScale(of: track, thresholds: thresholds) else {
            return nil
        }
        if scale.usedFallback {
            warnings.append("Body height estimated from torso length because ankles were rarely visible.")
        }
        if !scale.isReliable {
            warnings.append("Body height estimate is unstable, so distances are approximate.")
        }
        if scale.usedFallback || !scale.isReliable {
            warnings.append("Recompute after filming with the full body in frame.")
        }

        // Per frame centroid, absent when the torso is not visible enough to trust.
        var samples: [(tMs: Int, point: NormalizedPoint)] = []
        samples.reserveCapacity(track.frames.count)
        for frame in track.frames where frame.coverage >= thresholds.minimumFrameCoverage {
            if let point = centroid(of: frame) {
                samples.append((frame.tMs, point))
            }
        }

        guard samples.count >= 3 else { return nil }

        // Keep the longest run whose gaps are all fillable. A clip with a long occlusion is
        // analysed up to that point rather than silently bridged across it.
        let runs = contiguousRuns(samples: samples, maximumGapMs: thresholds.maximumInterpolationGapMs)
        guard let run = runs.max(by: { $0.count < $1.count }), run.count >= 3 else { return nil }

        if run.count != samples.count {
            warnings.append("Only the longest continuously tracked segment was analysed.")
        }

        guard
            let first = run.first,
            let last = run.last,
            last.tMs > first.tMs
        else { return nil }

        let analysisHz = thresholds.analysisHz
        let dt = 1.0 / analysisHz
        let sampleCount = max(2, Int((Double(last.tMs - first.tMs) / 1000 * analysisHz).rounded()) + 1)

        var rawX = [Double](repeating: 0, count: sampleCount)
        var rawY = [Double](repeating: 0, count: sampleCount)
        var cursor = 0
        for index in 0..<sampleCount {
            let t = Double(first.tMs) + Double(index) / analysisHz * 1000
            while cursor + 1 < run.count, Double(run[cursor + 1].tMs) < t {
                cursor += 1
            }
            let a = run[cursor]
            let b = run[min(cursor + 1, run.count - 1)]
            let span = Double(b.tMs - a.tMs)
            let weight = span > 0 ? min(1, max(0, (t - Double(a.tMs)) / span)) : 0
            rawX[index] = a.point.x + (b.point.x - a.point.x) * weight
            rawY[index] = a.point.y + (b.point.y - a.point.y) * weight
        }

        var xFilter = OneEuroFilter()
        var yFilter = OneEuroFilter()
        var smoothedX = [Double](repeating: 0, count: sampleCount)
        var smoothedY = [Double](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            smoothedX[index] = xFilter.filter(rawX[index], dt: dt)
            smoothedY[index] = yFilter.filter(rawY[index], dt: dt)
        }

        // Image y grows downward, so the lowest centroid has the largest y.
        let lowestY = smoothedY.max() ?? 0
        let height = smoothedY.map { max(0, (lowestY - $0)) / scale.medianBodyHeight }

        let verticalSpeed = SeriesMath.derivative(height, samplingHz: analysisHz)
        let horizontalSpeed = SeriesMath.derivative(
            smoothedX.map { $0 / scale.medianBodyHeight },
            samplingHz: analysisHz
        )
        var speed = [Double](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            speed[index] = (horizontalSpeed[index] * horizontalSpeed[index]
                + verticalSpeed[index] * verticalSpeed[index]).squareRoot()
        }
        speed = SeriesMath.movingAverage(speed, windowMs: 100, samplingHz: analysisHz)

        let quality = PoseTrackQuality.measure(track)

        return PreparedTrack(
            samplingHz: analysisHz,
            startMs: first.tMs,
            endMs: last.tMs,
            bodyScale: scale,
            x: smoothedX,
            y: smoothedY,
            height: height,
            speed: speed,
            horizontalSpeed: SeriesMath.movingAverage(
                horizontalSpeed,
                windowMs: 100,
                samplingHz: analysisHz
            ),
            verticalSpeed: verticalSpeed,
            coverage: quality.averageCoverage,
            warnings: warnings
        )
    }

    // MARK: - Body scale

    static func bodyScale(of track: PoseTrack, thresholds: MetricThresholds) -> BodyScale? {
        var headToAnkle: [Double] = []
        var torsoBased: [Double] = []

        for frame in track.frames {
            let head = usable(frame.joints[.nose]) ?? usable(frame.joints[.neck])
            let ankles = [PoseJoint.leftAnkle, .rightAnkle]
                .compactMap { usable(frame.joints[$0]) }

            if let head, !ankles.isEmpty {
                let ankleY = ankles.map(\.y).reduce(0, +) / Double(ankles.count)
                let span = ankleY - head.y
                if span > 0.05 {
                    headToAnkle.append(span)
                }
            }

            if let torso = torsoLength(of: frame.joints) {
                torsoBased.append(torso)
            }
        }

        let usableFrameCount = track.frames.filter { $0.coverage >= thresholds.minimumFrameCoverage }.count
        let minimumSamples = max(5, Int(Double(max(1, usableFrameCount)) * 0.2))

        if headToAnkle.count >= minimumSamples, let median = SeriesMath.median(headToAnkle) {
            let lower = SeriesMath.percentile(headToAnkle, 0.25) ?? median
            let upper = SeriesMath.percentile(headToAnkle, 0.75) ?? median
            let spread = median > 0 ? (upper - lower) / median : 1
            return BodyScale(
                medianBodyHeight: median,
                relativeSpread: spread,
                isReliable: spread <= 0.25,
                usedFallback: false
            )
        }

        // Fallback: torso length times an anthropometric factor. This is an approximation, marked
        // as such, and it is why the corpus measurement matters.
        if torsoBased.count >= minimumSamples,
           let medianTorso = SeriesMath.median(torsoBased) {
            let lower = SeriesMath.percentile(torsoBased, 0.25) ?? medianTorso
            let upper = SeriesMath.percentile(torsoBased, 0.75) ?? medianTorso
            let spread = medianTorso > 0 ? (upper - lower) / medianTorso : 1
            return BodyScale(
                medianBodyHeight: medianTorso * 3.0,
                relativeSpread: spread,
                isReliable: false,
                usedFallback: true
            )
        }

        return nil
    }

    static func torsoLength(of joints: [PoseJoint: JointSample]) -> Double? {
        let shoulders = [PoseJoint.leftShoulder, .rightShoulder].compactMap { usable(joints[$0]) }
        let hips = [PoseJoint.leftHip, .rightHip].compactMap { usable(joints[$0]) }
        guard !shoulders.isEmpty, !hips.isEmpty else { return nil }

        let shoulderMid = NormalizedPoint(
            x: shoulders.map(\.x).reduce(0, +) / Double(shoulders.count),
            y: shoulders.map(\.y).reduce(0, +) / Double(shoulders.count)
        )
        let hipMid = NormalizedPoint(
            x: hips.map(\.x).reduce(0, +) / Double(hips.count),
            y: hips.map(\.y).reduce(0, +) / Double(hips.count)
        )
        let dx = shoulderMid.x - hipMid.x
        let dy = shoulderMid.y - hipMid.y
        let length = (dx * dx + dy * dy).squareRoot()
        return length > 0.01 ? length : nil
    }

    // MARK: - Centroid

    static func centroid(of frame: PoseFrame) -> NormalizedPoint? {
        let hips = [PoseJoint.leftHip, .rightHip].compactMap { usable(frame.joints[$0]) }
        let shoulders = [PoseJoint.leftShoulder, .rightShoulder]
            .compactMap { usable(frame.joints[$0]) }
        guard !hips.isEmpty, !shoulders.isEmpty else { return nil }

        let points = hips + shoulders
        return NormalizedPoint(
            x: points.map(\.x).reduce(0, +) / Double(points.count),
            y: points.map(\.y).reduce(0, +) / Double(points.count)
        )
    }

    private static func usable(_ sample: JointSample?) -> JointSample? {
        guard let sample, sample.isUsable else { return nil }
        return sample
    }

    // MARK: - Runs

    static func contiguousRuns(
        samples: [(tMs: Int, point: NormalizedPoint)],
        maximumGapMs: Int
    ) -> [[(tMs: Int, point: NormalizedPoint)]] {
        var runs: [[(tMs: Int, point: NormalizedPoint)]] = []
        var current: [(tMs: Int, point: NormalizedPoint)] = []

        for sample in samples {
            if let previous = current.last, sample.tMs - previous.tMs > maximumGapMs {
                if current.count > 1 { runs.append(current) }
                current = []
            }
            current.append(sample)
        }
        if current.count > 1 { runs.append(current) }
        return runs
    }
}
