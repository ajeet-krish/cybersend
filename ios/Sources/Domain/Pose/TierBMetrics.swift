import Foundation

/// The Tier B events: things a pose track can tell you about movement without knowing where the
/// holds are.
///
/// All three are pose-only proxies, not contact measurements. A dyno is a fast hand movement, not
/// proof that the hand left a hold; cut feet is both ankles rising toward the hips, not proof that
/// the feet left the wall; a rest is a still period inside the attempt, not proof of a no-hands
/// shakeout. Hold contact is Pose v2 and needs either hold detection or a homography
/// (docs/decisions.md, 2026-10-21 Phase 5 record), so nothing here may be presented as contact.
public struct TierBEventSet: Equatable, Sendable {
    public var dynoEvents: [DetectedEvent]
    public var cutFeetEvents: [DetectedEvent]
    public var restEvents: [DetectedEvent]

    public init(
        dynoEvents: [DetectedEvent] = [],
        cutFeetEvents: [DetectedEvent] = [],
        restEvents: [DetectedEvent] = []
    ) {
        self.dynoEvents = dynoEvents
        self.cutFeetEvents = cutFeetEvents
        self.restEvents = restEvents
    }

    public var all: [DetectedEvent] {
        dynoEvents + cutFeetEvents + restEvents
    }
}

/// Tier B over a raw pose track and its prepared centroid series.
///
/// The raw track is needed because the prepared track keeps only the body centroid, and all three
/// Tier B signals live in the limbs. Limb samples are resampled onto the prepared grid so every
/// series shares one time base and one smoothing pass.
public enum TierBMetricsEngine {
    public static func compute(
        track: PoseTrack,
        prepared: PreparedTrack,
        attemptWindow: AttemptWindow,
        thresholds: MetricThresholds = MetricThresholds()
    ) -> TierBEventSet {
        guard prepared.sampleCount > 2 else { return TierBEventSet() }

        let wrists = [
            limb(.leftWrist, track: track, prepared: prepared, thresholds: thresholds),
            limb(.rightWrist, track: track, prepared: prepared, thresholds: thresholds),
        ]
        let ankles = [
            limb(.leftAnkle, track: track, prepared: prepared, thresholds: thresholds),
            limb(.rightAnkle, track: track, prepared: prepared, thresholds: thresholds),
        ]
        let hips = limb(.leftHip, track: track, prepared: prepared, thresholds: thresholds)
        let rightHips = limb(.rightHip, track: track, prepared: prepared, thresholds: thresholds)

        return TierBEventSet(
            dynoEvents: detectDynos(
                wrists: wrists,
                prepared: prepared,
                window: attemptWindow,
                thresholds: thresholds
            ),
            cutFeetEvents: detectCutFeet(
                ankles: ankles,
                hips: hips,
                rightHips: rightHips,
                prepared: prepared,
                window: attemptWindow,
                thresholds: thresholds
            ),
            restEvents: detectRests(
                prepared: prepared,
                window: attemptWindow,
                thresholds: thresholds
            )
        )
    }

    // MARK: - Limb series

    /// One joint on the prepared grid, in normalized image coordinates. Nil where the joint was
    /// not visible enough to trust, so a gap never turns into a fake jump.
    struct LimbSeries {
        var joint: PoseJoint
        var x: [Double?]
        var y: [Double?]
        var count: Int { x.count }
    }

    /// Nearest usable sample within this tolerance is used; longer gaps stay nil.
    static let limbSampleToleranceMs = 80

    static func limb(
        _ joint: PoseJoint,
        track: PoseTrack,
        prepared: PreparedTrack,
        thresholds: MetricThresholds
    ) -> LimbSeries {
        let frames = track.frames
        var x = [Double?](repeating: nil, count: prepared.sampleCount)
        var y = [Double?](repeating: nil, count: prepared.sampleCount)
        guard !frames.isEmpty else { return LimbSeries(joint: joint, x: x, y: y) }

        var cursor = 0
        for index in 0..<prepared.sampleCount {
            let t = prepared.timeMs(at: index)
            while cursor + 1 < frames.count,
                  abs(frames[cursor + 1].tMs - t) <= abs(frames[cursor].tMs - t) {
                cursor += 1
            }
            let frame = frames[cursor]
            guard
                abs(frame.tMs - t) <= limbSampleToleranceMs,
                let sample = frame.joints[joint],
                sample.isUsable
            else { continue }
            x[index] = sample.x
            y[index] = sample.y
        }

        smooth(&x, samplingHz: prepared.samplingHz)
        smooth(&y, samplingHz: prepared.samplingHz)
        return LimbSeries(joint: joint, x: x, y: y)
    }

    /// Smooths each contiguous valid run on its own, so a gap never drags a filter across it.
    static func smooth(_ values: inout [Double?], samplingHz: Double) {
        let dt = samplingHz > 0 ? 1 / samplingHz : 1 / 30
        var index = 0
        while index < values.count {
            guard values[index] != nil else {
                index += 1
                continue
            }
            var filter = OneEuroFilter()
            var end = index
            while end < values.count, let value = values[end] {
                values[end] = filter.filter(value, dt: dt)
                end += 1
            }
            index = end
        }
    }

    /// Speed in body heights per second, central difference on the prepared grid. Nil unless the
    /// samples on both sides exist, so an occlusion cannot invent a spike.
    static func speed(
        _ series: LimbSeries,
        bodyScale: Double,
        samplingHz: Double
    ) -> [Double?] {
        var result = [Double?](repeating: nil, count: series.count)
        guard series.count > 2, bodyScale > 0, samplingHz > 0 else { return result }
        let dt = 2 / samplingHz
        for index in 1..<(series.count - 1) {
            guard
                let x0 = series.x[index - 1], let x1 = series.x[index + 1],
                let y0 = series.y[index - 1], let y1 = series.y[index + 1]
            else { continue }
            let dx = (x1 - x0) / dt
            let dy = (y1 - y0) / dt
            result[index] = (dx * dx + dy * dy).squareRoot() / bodyScale
        }
        return result
    }

    // MARK: - Dyno

    static func detectDynos(
        wrists: [LimbSeries],
        prepared: PreparedTrack,
        window: AttemptWindow,
        thresholds: MetricThresholds
    ) -> [DetectedEvent] {
        var candidates: [DetectedEvent] = []

        for wrist in wrists {
            let speeds = speed(
                wrist,
                bodyScale: prepared.bodyScale.medianBodyHeight,
                samplingHz: prepared.samplingHz
            )
            guard speeds.count > 2 else { continue }
            for index in 1..<(speeds.count - 1) {
                guard let peak = speeds[index], peak >= thresholds.dynoMinimumHandSpeed else {
                    continue
                }
                guard (speeds[index - 1] ?? 0) <= peak, (speeds[index + 1] ?? 0) <= peak else {
                    continue
                }
                let t = prepared.timeMs(at: index)
                guard t >= window.startMs, t <= window.endMs else { continue }

                let half = max(
                    1,
                    Int((Double(thresholds.dynoWindowMs) / 2000 * prepared.samplingHz).rounded())
                )
                let low = max(0, index - half)
                let high = min(wrist.count - 1, index + half)
                guard
                    let x0 = wrist.x[low], let y0 = wrist.y[low],
                    let x1 = wrist.x[high], let y1 = wrist.y[high],
                    let xPeak = wrist.x[index], let yPeak = wrist.y[index]
                else { continue }
                let travel = (x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)
                let displacement = travel.squareRoot() / prepared.bodyScale.medianBodyHeight
                guard displacement >= thresholds.dynoMinimumDisplacement else { continue }

                candidates.append(DetectedEvent(
                    type: .dyno,
                    startMs: t,
                    joint: wrist.joint,
                    xNorm: xPeak,
                    yNorm: yPeak,
                    value: peak,
                    confidence: min(1, peak / (thresholds.dynoMinimumHandSpeed * 2))
                ))
            }
        }

        return debounce(candidates, minimumSpacingMs: thresholds.dynoDebounceMs)
    }

    // MARK: - Cut feet

    static func detectCutFeet(
        ankles: [LimbSeries],
        hips: LimbSeries,
        rightHips: LimbSeries,
        prepared: PreparedTrack,
        window: AttemptWindow,
        thresholds: MetricThresholds
    ) -> [DetectedEvent] {
        guard ankles.count == 2 else { return [] }
        let scale = prepared.bodyScale.medianBodyHeight
        guard scale > 0 else { return [] }

        // Hip midpoint per sample. Both hips must be visible; one visible hip is not enough to
        // say where the body is.
        var hipY = [Double?](repeating: nil, count: prepared.sampleCount)
        for index in 0..<prepared.sampleCount {
            guard let left = hips.y[index], let right = rightHips.y[index] else { continue }
            hipY[index] = (left + right) / 2
        }

        // Offset below the hips in body heights. Smaller means the ankle rose toward the hips.
        var offsets: [[Double?]] = []
        for ankle in ankles {
            var series = [Double?](repeating: nil, count: prepared.sampleCount)
            for index in 0..<prepared.sampleCount {
                guard let ankleY = ankle.y[index], let hip = hipY[index] else { continue }
                series[index] = (ankleY - hip) / scale
            }
            offsets.append(series)
        }

        let steps = max(
            1,
            Int((Double(thresholds.cutFeetWindowMs) / 1000 * prepared.samplingHz).rounded())
        )
        var candidates: [DetectedEvent] = []

        guard prepared.sampleCount > steps else { return [] }
        for index in steps..<prepared.sampleCount {
            let t = prepared.timeMs(at: index)
            guard t >= window.startMs, t <= window.endMs else { continue }

            var minimumRise = Double.infinity
            var allPresent = true
            for series in offsets {
                guard let now = series[index], let before = series[index - steps] else {
                    allPresent = false
                    break
                }
                minimumRise = min(minimumRise, before - now)
            }
            guard allPresent, minimumRise >= thresholds.cutFeetMinimumRise else { continue }

            // The body must not simply be rising: that is a high step, not feet cutting loose.
            let bodyRise = prepared.height[index] - prepared.height[index - steps]
            guard bodyRise <= thresholds.cutFeetMaximumBodyRise else { continue }

            let startMs = prepared.timeMs(at: index - steps)
            var xSum = 0.0
            var ySum = 0.0
            var samples = 0
            for ankle in ankles {
                if let x = ankle.x[index], let y = ankle.y[index] {
                    xSum += x
                    ySum += y
                    samples += 1
                }
            }

            candidates.append(DetectedEvent(
                type: .cutFeet,
                startMs: startMs,
                endMs: t,
                xNorm: samples > 0 ? xSum / Double(samples) : nil,
                yNorm: samples > 0 ? ySum / Double(samples) : nil,
                value: minimumRise,
                confidence: min(1, minimumRise / (thresholds.cutFeetMinimumRise * 1.5))
            ))
        }

        return debounce(candidates, minimumSpacingMs: thresholds.cutFeetDebounceMs)
    }

    // MARK: - Rest

    static func detectRests(
        prepared: PreparedTrack,
        window: AttemptWindow,
        thresholds: MetricThresholds
    ) -> [DetectedEvent] {
        var events: [DetectedEvent] = []
        var runStart: Int?

        func close(_ endIndex: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let finalIndex = max(start, endIndex)
            let startMs = prepared.timeMs(at: start)
            let endMs = prepared.timeMs(at: finalIndex)
            let duration = endMs - startMs
            guard duration >= thresholds.restMinimumMs else { return }
            events.append(DetectedEvent(
                type: .rest,
                startMs: startMs,
                endMs: endMs,
                value: Double(duration) / 1000,
                confidence: min(1, Double(duration) / Double(thresholds.restMinimumMs * 2))
            ))
        }

        for index in 0..<prepared.sampleCount {
            let t = prepared.timeMs(at: index)
            let inside = t >= window.startMs && t <= window.endMs
            let still = prepared.speed[index] < thresholds.restSpeed
            if inside, still {
                if runStart == nil { runStart = index }
            } else {
                close(index - 1)
            }
        }
        close(prepared.sampleCount - 1)
        return events
    }

    // MARK: - Debounce

    /// Keeps the strongest candidate inside each spacing window, in clip order. Two wrists can
    /// both fire for one dyno, and one cut feet can fire on several consecutive samples.
    static func debounce(_ candidates: [DetectedEvent], minimumSpacingMs: Int) -> [DetectedEvent] {
        let ordered = candidates.sorted { $0.startMs < $1.startMs }
        var kept: [DetectedEvent] = []
        for candidate in ordered {
            guard let last = kept.last else {
                kept.append(candidate)
                continue
            }
            if candidate.startMs - last.startMs < minimumSpacingMs {
                if candidate.confidence > last.confidence {
                    kept[kept.count - 1] = candidate
                }
            } else {
                kept.append(candidate)
            }
        }
        return kept
    }
}
