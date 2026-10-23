import Foundation

/// A point in normalized image space, top left origin.
public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A single scalar at a point in clip time.
public struct MetricSample: Codable, Equatable, Sendable {
    public var tMs: Int
    public var value: Double

    public init(tMs: Int, value: Double) {
        self.tMs = tMs
        self.value = value
    }
}

/// The detected attempt inside a clip.
public struct AttemptWindow: Codable, Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var confidence: Double
    /// False when the boundaries fell back to the clip edges instead of motion.
    public var detectedByMotion: Bool

    public init(startMs: Int, endMs: Int, confidence: Double, detectedByMotion: Bool) {
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
        self.detectedByMotion = detectedByMotion
    }

    public var durationMs: Int { max(0, endMs - startMs) }
}

/// Something the metrics engine saw, before it is assigned an analysis id for storage.
public struct DetectedEvent: Codable, Equatable, Sendable {
    public var type: AnalysisEventType
    public var startMs: Int
    public var endMs: Int?
    public var joint: PoseJoint?
    public var xNorm: Double?
    public var yNorm: Double?
    public var value: Double?
    public var confidence: Double

    public init(
        type: AnalysisEventType,
        startMs: Int,
        endMs: Int? = nil,
        joint: PoseJoint? = nil,
        xNorm: Double? = nil,
        yNorm: Double? = nil,
        value: Double? = nil,
        confidence: Double
    ) {
        self.type = type
        self.startMs = startMs
        self.endMs = endMs
        self.joint = joint
        self.xNorm = xNorm
        self.yNorm = yNorm
        self.value = value
        self.confidence = confidence
    }
}

/// Time spent nearly still, binned by where in the frame it happened.
///
/// Coordinates are image normalized, so the map is only comparable between clips that share a
/// camera pose. Comparison is gated on the camera class for exactly this reason.
public struct HesitationMap: Codable, Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    /// Row major, each cell normalized to the busiest cell in the map.
    public var weights: [Double]
    public var peakDwellMs: Double

    public init(columns: Int, rows: Int, weights: [Double], peakDwellMs: Double) {
        self.columns = columns
        self.rows = rows
        self.weights = weights
        self.peakDwellMs = peakDwellMs
    }
}

/// Tier A outputs: everything that does not need hold geometry.
public struct TierAMetrics: Codable, Equatable, Sendable {
    public var algorithmVersion: Int
    public var thresholdsVersion: Int
    public var bodyScale: BodyScale
    public var cameraClass: CameraStabilityClass
    /// Score 0 to 1 for how much the clip can be trusted, derived from coverage and scale spread.
    public var quality: Double
    public var attemptWindow: AttemptWindow
    /// Everything worth storing as an analysis event, in clip order: the attempt boundaries, any
    /// falls, and the Tier B movement events.
    public var events: [DetectedEvent]
    public var fallEvents: [DetectedEvent]
    /// Fast hand movement. A pose-only proxy, not proof the hand left a hold.
    public var dynoEvents: [DetectedEvent]
    /// Both ankles rising toward the hips. A pose-only proxy, not proof the feet left the wall.
    public var cutFeetEvents: [DetectedEvent]
    /// Still periods inside the attempt.
    public var restEvents: [DetectedEvent]
    /// Height above the lowest centroid, in body heights, sampled at the progress rate.
    public var progress: [MetricSample]
    public var highestPoint: MetricSample?
    public var peakSpeed: Double?
    public var smoothness: Double?
    public var pathEfficiency: Double?
    public var hesitation: HesitationMap?
    public var warnings: [String]

    public var isUsable: Bool {
        attemptWindow.detectedByMotion
            && attemptWindow.durationMs >= 500
            && quality >= 0.4
    }
}

/// Pure Tier A metrics over a pose track. No Vision, no AVFoundation, no database.
public enum TierAMetricsEngine {
    /// Bumped when the maths changes in a way that moves a number, or when the event set changes.
    /// Version 2 adds the Tier B events, so an analysis from version 1 is missing them.
    public static let algorithmVersion = 2

    public static func compute(
        track: PoseTrack,
        thresholds: MetricThresholds = MetricThresholds()
    ) -> TierAMetrics? {
        guard let prepared = TrackPreparation.prepare(track, thresholds: thresholds) else {
            return nil
        }
        return compute(track: track, prepared: prepared, thresholds: thresholds)
    }

    public static func compute(
        track: PoseTrack,
        prepared: PreparedTrack,
        thresholds: MetricThresholds = MetricThresholds()
    ) -> TierAMetrics {
        var warnings = prepared.warnings

        let cameraClass = classifyCamera(prepared, thresholds: thresholds)
        if cameraClass == .handheld {
            warnings.append("Handheld camera, so comparison with other clips is disabled.")
        }

        let falls = detectFalls(prepared, thresholds: thresholds)
        let window = detectAttemptWindow(prepared, falls: falls, thresholds: thresholds, warnings: &warnings)
        let range = window.start..<max(window.start + 1, window.end + 1)

        let progress = progressCurve(prepared, range: range, thresholds: thresholds)
        let highestPoint = progress.max(by: { $0.value < $1.value })

        let peakSpeed = range.isEmpty ? nil : prepared.speed[range].max()

        let smoothing = smoothness(prepared, range: range, thresholds: thresholds)
        if smoothing == nil {
            warnings.append("Path too short for a smoothness score.")
        }

        let hesitation = hesitationMap(prepared, range: range, thresholds: thresholds)

        let quality = min(
            1,
            prepared.coverage * 0.6
                + (prepared.bodyScale.isReliable ? 0.4 : 0.15)
        )

        let tierB = TierBMetricsEngine.compute(
            track: track,
            prepared: prepared,
            attemptWindow: AttemptWindow(
                startMs: window.startMs,
                endMs: window.endMs,
                confidence: window.confidence,
                detectedByMotion: window.detectedByMotion
            ),
            thresholds: thresholds
        )

        var events = falls + tierB.all
        events.append(DetectedEvent(
            type: .attemptStart,
            startMs: window.startMs,
            confidence: window.confidence
        ))
        events.append(DetectedEvent(
            type: .attemptEnd,
            startMs: window.endMs,
            confidence: window.confidence
        ))
        events.sort { lhs, rhs in
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            return Self.eventOrder(lhs.type) < Self.eventOrder(rhs.type)
        }

        return TierAMetrics(
            algorithmVersion: algorithmVersion,
            thresholdsVersion: thresholds.version,
            bodyScale: prepared.bodyScale,
            cameraClass: cameraClass,
            quality: quality,
            attemptWindow: AttemptWindow(
                startMs: window.startMs,
                endMs: window.endMs,
                confidence: window.confidence,
                detectedByMotion: window.detectedByMotion
            ),
            events: events,
            fallEvents: falls,
            dynoEvents: tierB.dynoEvents,
            cutFeetEvents: tierB.cutFeetEvents,
            restEvents: tierB.restEvents,
            progress: progress,
            highestPoint: highestPoint,
            peakSpeed: peakSpeed,
            smoothness: smoothing?.logDimensionlessJerk,
            pathEfficiency: smoothing?.pathEfficiency,
            hesitation: hesitation,
            warnings: warnings
        )
    }

    // MARK: - Events

    /// Ties in clip time are broken deterministically: the attempt opens, the fall happens, the
    /// attempt closes. Without this a fall and an attempt end at the same millisecond could be
    /// stored in either order depending on the sort implementation.
    static func eventOrder(_ type: AnalysisEventType) -> Int {
        switch type {
        case .attemptStart: return 0
        case .fall: return 1
        case .dyno: return 2
        case .cutFeet: return 3
        case .rest: return 4
        case .attemptEnd: return 5
        }
    }

    // MARK: - Camera class

    static func classifyCamera(
        _ prepared: PreparedTrack,
        thresholds: MetricThresholds
    ) -> CameraStabilityClass {
        let absolute = prepared.horizontalSpeed.map(abs)
        let lowPassed = SeriesMath.movingAverage(absolute, windowMs: 1000, samplingHz: prepared.samplingHz)
        let median = SeriesMath.percentile(lowPassed, 0.6) ?? 0
        if median <= thresholds.cameraStaticHorizontal {
            return .stationary
        }
        if median <= thresholds.cameraNearStaticHorizontal {
            return .nearStatic
        }
        return .handheld
    }

    // MARK: - Attempt window

    struct WindowIndices {
        var start: Int
        var end: Int
        var confidence: Double
        var detectedByMotion: Bool
        var startMs: Int
        var endMs: Int
    }

    static func detectAttemptWindow(
        _ prepared: PreparedTrack,
        falls: [DetectedEvent],
        thresholds: MetricThresholds,
        warnings: inout [String]
    ) -> WindowIndices {
        let count = prepared.sampleCount
        let dtMs = 1000 / prepared.samplingHz

        let sustainSamples = max(1, Int(Double(thresholds.sustainedStartMs) / dtMs))
        let restSamples = max(1, Int(Double(thresholds.minimumRestMs) / dtMs))
        let quietSamples = max(1, Int(Double(thresholds.quietEndMs) / dtMs))

        var startIndex: Int?
        var restSatisfied = false

        for index in 0..<count {
            guard prepared.speed[index] >= thresholds.startSpeed else { continue }
            let end = min(count, index + sustainSamples)
            let sustained = (index..<end).allSatisfy { prepared.speed[$0] >= thresholds.startSpeed * 0.6 }
            guard sustained else { continue }

            let restStart = max(0, index - restSamples)
            let rested = (restStart..<index).allSatisfy { prepared.speed[$0] < thresholds.restSpeed }
            startIndex = index
            restSatisfied = rested || restStart == 0
            break
        }

        guard let start = startIndex else {
            warnings.append("No movement detected, so the whole clip is treated as the attempt.")
            let endMs = prepared.timeMs(at: count - 1)
            return WindowIndices(
                start: 0,
                end: count - 1,
                confidence: 0.25,
                detectedByMotion: false,
                startMs: prepared.timeMs(at: 0),
                endMs: endMs
            )
        }

        var confidence = restSatisfied ? 0.85 : 0.6
        if !restSatisfied {
            warnings.append("The clip starts with movement, so the attempt start is approximate.")
        }

        // A fall ends the attempt exactly where it begins.
        if let fall = falls.first(where: { $0.startMs > prepared.timeMs(at: start) }) {
            return WindowIndices(
                start: start,
                end: prepared.index(atOrBefore: fall.startMs),
                confidence: confidence,
                detectedByMotion: true,
                startMs: prepared.timeMs(at: start),
                endMs: fall.startMs
            )
        }

        var endIndex: Int?
        var index = start + quietSamples
        while index < count {
            let quietRange = (index - quietSamples)..<index
            let quiet = quietRange.allSatisfy { prepared.speed[$0] < thresholds.restSpeed }
            if quiet, prepared.height[index] <= thresholds.endHeightBand {
                endIndex = index
                break
            }
            index += max(1, quietSamples / 2)
        }

        if let end = endIndex {
            return WindowIndices(
                start: start,
                end: end,
                confidence: confidence,
                detectedByMotion: true,
                startMs: prepared.timeMs(at: start),
                endMs: prepared.timeMs(at: end)
            )
        }

        confidence = max(0.35, confidence - 0.35)
        warnings.append("The attempt end is the clip end, so the window may include recovery time.")
        return WindowIndices(
            start: start,
            end: count - 1,
            confidence: confidence,
            detectedByMotion: true,
            startMs: prepared.timeMs(at: start),
            endMs: prepared.timeMs(at: count - 1)
        )
    }

    // MARK: - Falls

    static func detectFalls(
        _ prepared: PreparedTrack,
        thresholds: MetricThresholds
    ) -> [DetectedEvent] {
        let count = prepared.sampleCount
        guard count > 4 else { return [] }

        let dtMs = 1000 / prepared.samplingHz
        let lookback = max(2, Int(300 / dtMs))
        let dropSamples = max(2, Int(Double(thresholds.fallMaximumDropMs) / dtMs))
        let peakHeight = prepared.height.max() ?? 0

        var events: [DetectedEvent] = []
        var lastFallMs: Int?

        for index in 1..<(count - 1) {
            let peak = prepared.height[index]
            // Local maximum, so the fall is reported where it starts rather than somewhere on
            // the way down.
            let from = max(0, index - lookback)
            let to = min(count - 1, index + lookback)
            guard peak >= ((from...to).map { prepared.height[$0] }.max() ?? peak) else { continue }
            guard peak >= 0.25 else { continue }

            let searchEnd = min(count - 1, index + dropSamples)
            var lowestIndex = index
            var lowestHeight = peak
            var peakDownSpeed = 0.0
            for probe in index...searchEnd {
                if prepared.height[probe] < lowestHeight {
                    lowestHeight = prepared.height[probe]
                    lowestIndex = probe
                }
                peakDownSpeed = min(peakDownSpeed, prepared.verticalSpeed[probe])
            }

            let drop = peak - lowestHeight
            guard drop >= thresholds.fallMinimumDrop else { continue }
            guard peakDownSpeed <= -thresholds.fallMinimumDownSpeed else { continue }

            let startMs = prepared.timeMs(at: index)
            if let last = lastFallMs, startMs - last <= thresholds.fallDebounceMs {
                continue
            }

            let horizontalDrift = abs(prepared.x[lowestIndex] - prepared.x[index])
                / prepared.bodyScale.medianBodyHeight
            var confidence = 0.7
            if horizontalDrift > thresholds.fallHorizontalDriftSoftLimit {
                confidence -= 0.25
            }
            if drop < peakHeight * 0.5 {
                confidence -= 0.1
            }

            events.append(DetectedEvent(
                type: .fall,
                startMs: startMs,
                endMs: prepared.timeMs(at: lowestIndex),
                joint: .root,
                xNorm: prepared.x[index],
                yNorm: prepared.y[index],
                value: drop,
                confidence: max(0.2, confidence)
            ))
            lastFallMs = startMs
        }

        return events
    }

    // MARK: - Progress

    static func progressCurve(
        _ prepared: PreparedTrack,
        range: Range<Int>,
        thresholds: MetricThresholds
    ) -> [MetricSample] {
        guard !range.isEmpty else { return [] }
        let step = max(1, Int((prepared.samplingHz / thresholds.progressHz).rounded()))
        var samples: [MetricSample] = []
        var index = range.lowerBound
        while index < range.upperBound {
            samples.append(MetricSample(
                tMs: prepared.timeMs(at: index),
                value: prepared.height[index]
            ))
            index += step
        }
        if let last = samples.last {
            let endIndex = min(range.upperBound - 1, prepared.sampleCount - 1)
            if last.tMs != prepared.timeMs(at: endIndex) {
                samples.append(MetricSample(
                    tMs: prepared.timeMs(at: endIndex),
                    value: prepared.height[endIndex]
                ))
            }
        }
        return samples
    }

    // MARK: - Smoothness

    struct Smoothness {
        var logDimensionlessJerk: Double
        var pathEfficiency: Double
    }

    static func smoothness(
        _ prepared: PreparedTrack,
        range: Range<Int>,
        thresholds: MetricThresholds
    ) -> Smoothness? {
        guard range.count >= 5 else { return nil }
        let scale = prepared.bodyScale.medianBodyHeight
        guard scale > 0 else { return nil }

        let xs = range.map { prepared.x[$0] / scale }
        let ys = range.map { prepared.y[$0] / scale }

        var pathLength = 0.0
        for index in 1..<xs.count {
            let dx = xs[index] - xs[index - 1]
            let dy = ys[index] - ys[index - 1]
            pathLength += (dx * dx + dy * dy).squareRoot()
        }
        guard pathLength >= thresholds.smoothnessMinimumPathLength else { return nil }

        let hz = prepared.samplingHz
        let ax = SeriesMath.derivative(SeriesMath.derivative(xs, samplingHz: hz), samplingHz: hz)
        let jx = SeriesMath.derivative(ax, samplingHz: hz)
        let ay = SeriesMath.derivative(SeriesMath.derivative(ys, samplingHz: hz), samplingHz: hz)
        let jy = SeriesMath.derivative(ay, samplingHz: hz)

        var integral = 0.0
        for index in jx.indices {
            integral += jx[index] * jx[index] + jy[index] * jy[index]
        }
        integral /= hz

        let duration = Double(range.count - 1) / hz
        let displacement = ((xs.last! - xs.first!).magnitudeSquared
            + (ys.last! - ys.first!).magnitudeSquared).squareRoot()

        let jerk: Double
        if integral <= 1e-12 {
            // Perfectly straight or perfectly still: cap rather than returning infinity.
            jerk = 6.0
        } else {
            let normalized = pow(duration, 5) / (pathLength * pathLength) * integral
            jerk = -log(max(normalized, 1e-12))
        }

        return Smoothness(
            logDimensionlessJerk: jerk,
            pathEfficiency: pathLength > 0 ? min(1, max(0, displacement / pathLength)) : 0
        )
    }

    // MARK: - Hesitation

    static func hesitationMap(
        _ prepared: PreparedTrack,
        range: Range<Int>,
        thresholds: MetricThresholds
    ) -> HesitationMap? {
        guard !range.isEmpty else { return nil }
        let columns = max(1, thresholds.hesitationColumns)
        let rows = max(1, thresholds.hesitationRows)
        var weights = [Double](repeating: 0, count: columns * rows)
        let dtMs = 1000 / prepared.samplingHz

        for index in range where prepared.speed[index] < thresholds.hesitationSpeed {
            let column = min(columns - 1, max(0, Int(prepared.x[index] * Double(columns))))
            let row = min(rows - 1, max(0, Int(prepared.y[index] * Double(rows))))
            weights[row * columns + column] += dtMs
        }

        guard let peak = weights.max(), peak > 0 else { return nil }
        return HesitationMap(
            columns: columns,
            rows: rows,
            weights: weights.map { $0 / peak },
            peakDwellMs: peak
        )
    }
}

private extension Double {
    var magnitudeSquared: Double { self * self }
}
