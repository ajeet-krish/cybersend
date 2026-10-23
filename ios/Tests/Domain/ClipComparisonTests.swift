import Foundation
import Testing
@testable import CyberSendDomain

// Comparison (P6): two clips on metrics only, gated on camera stability. The fixtures build
// TierAMetrics directly rather than through the engine, because the comparison model must not
// depend on how a number was produced, only on the number and the camera class that gates it.

private func scale() -> BodyScale {
    BodyScale(medianBodyHeight: 0.53, relativeSpread: 0.08, isReliable: true, usedFallback: false)
}

private func event(_ type: AnalysisEventType, startMs: Int, endMs: Int? = nil) -> DetectedEvent {
    DetectedEvent(type: type, startMs: startMs, endMs: endMs, confidence: 0.9)
}

private func metrics(
    cameraClass: CameraStabilityClass = .stationary,
    durationMs: Int = 10_000,
    progress: [MetricSample] = [
        MetricSample(tMs: 0, value: 0),
        MetricSample(tMs: 5_000, value: 0.5),
        MetricSample(tMs: 10_000, value: 1),
    ],
    falls: [DetectedEvent] = [],
    dynos: [DetectedEvent] = [],
    cutFeet: [DetectedEvent] = [],
    rests: [DetectedEvent] = [],
    hesitation: HesitationMap? = nil
) -> TierAMetrics {
    let window = AttemptWindow(
        startMs: 0,
        endMs: durationMs,
        confidence: 0.9,
        detectedByMotion: true
    )
    return TierAMetrics(
        algorithmVersion: TierAMetricsEngine.algorithmVersion,
        thresholdsVersion: MetricThresholds().version,
        bodyScale: scale(),
        cameraClass: cameraClass,
        quality: 0.9,
        attemptWindow: window,
        events: [event(.attemptStart, startMs: 0)] + falls + dynos + cutFeet + rests
            + [event(.attemptEnd, startMs: durationMs)],
        fallEvents: falls,
        dynoEvents: dynos,
        cutFeetEvents: cutFeet,
        restEvents: rests,
        progress: progress,
        highestPoint: progress.max(by: { $0.value < $1.value }),
        peakSpeed: 1.2,
        smoothness: -2.4,
        pathEfficiency: 0.7,
        hesitation: hesitation,
        warnings: []
    )
}

private func hesitationMap() -> HesitationMap {
    HesitationMap(columns: 2, rows: 2, weights: [1, 0, 0.5, 0], peakDwellMs: 900)
}

@Suite("Clip comparison gate")
struct ClipComparisonGateTests {
    @Test("two fixed camera clips compare")
    func stationaryPairCompares() throws {
        let gate = ClipComparison.compare(
            left: (label: "Session 1", metrics: metrics()),
            right: (label: "Session 2", metrics: metrics(durationMs: 8_000))
        )
        guard case .allowed(let comparison) = gate else {
            Issue.record("two stationary clips must compare")
            return
        }
        #expect(comparison.left.label == "Session 1")
        #expect(comparison.right.label == "Session 2")
        #expect(comparison.left.durationMs == 10_000)
        #expect(comparison.right.durationMs == 8_000)
        #expect(comparison.spatialOverlayAllowed)
    }

    @Test("a handheld clip refuses comparison and says which one")
    func handheldRefuses() throws {
        let gate = ClipComparison.compare(
            left: (label: "Tripod clip", metrics: metrics()),
            right: (label: "Handheld clip", metrics: metrics(cameraClass: .handheld))
        )
        guard case .refused(let reason) = gate else {
            Issue.record("a handheld clip must refuse comparison")
            return
        }
        #expect(reason.contains("Handheld clip"))
        #expect(reason.contains("handheld"))
    }

    @Test("a nearly still clip compares on numbers but not on space")
    func nearStaticHasNoSpatialRead() throws {
        let gate = ClipComparison.compare(
            left: (label: "A", metrics: metrics()),
            right: (label: "B", metrics: metrics(cameraClass: .nearStatic, hesitation: hesitationMap()))
        )
        guard case .allowed(let comparison) = gate else {
            Issue.record("a nearly still clip is still comparable on numbers")
            return
        }
        #expect(comparison.spatialOverlayAllowed == false)
        #expect(comparison.left.hesitation == nil)
        #expect(comparison.right.hesitation == nil)
        #expect(comparison.notes.contains { $0.contains("hesitation") })
    }

    @Test("two fixed camera clips keep their hesitation maps")
    func stationaryKeepsHesitation() throws {
        let gate = ClipComparison.compare(
            left: (label: "A", metrics: metrics(hesitation: hesitationMap())),
            right: (label: "B", metrics: metrics(hesitation: hesitationMap()))
        )
        guard case .allowed(let comparison) = gate else {
            Issue.record("two stationary clips must compare")
            return
        }
        #expect(comparison.left.hesitation != nil)
        #expect(comparison.right.hesitation != nil)
    }
}

@Suite("Clip comparison numbers")
struct ClipComparisonNumbersTests {
    @Test("the side carries the counts and the rest total")
    func sideCarriesCounts() throws {
        let left = metrics(
            falls: [event(.fall, startMs: 3_000)],
            dynos: [event(.dyno, startMs: 4_000)],
            cutFeet: [event(.cutFeet, startMs: 5_000, endMs: 5_700)],
            rests: [
                event(.rest, startMs: 6_000, endMs: 8_500),
                event(.rest, startMs: 8_600, endMs: 9_600),
            ]
        )
        let gate = ClipComparison.compare(
            left: (label: "A", metrics: left),
            right: (label: "B", metrics: metrics())
        )
        guard case .allowed(let comparison) = gate else {
            Issue.record("the pair must compare")
            return
        }
        #expect(comparison.left.fallCount == 1)
        #expect(comparison.left.dynoCount == 1)
        #expect(comparison.left.cutFeetCount == 1)
        #expect(abs(comparison.left.restSeconds - 3.5) < 0.001)
        #expect(comparison.right.fallCount == 0)
    }

    @Test("the first fall is placed at its fraction of the attempt")
    func fallProgress() throws {
        let left = metrics(falls: [
            event(.fall, startMs: 7_500),
            event(.fall, startMs: 2_500),
        ])
        let gate = ClipComparison.compare(
            left: (label: "A", metrics: left),
            right: (label: "B", metrics: metrics())
        )
        guard case .allowed(let comparison) = gate else {
            Issue.record("the pair must compare")
            return
        }
        let progress = try #require(comparison.left.fallProgress)
        #expect(abs(progress - 0.25) < 0.001, "the earliest fall wins")
        #expect(comparison.right.fallProgress == nil)
    }

    @Test("the normalized curve spans the attempt from 0 to 1")
    func curveSpansAttempt() throws {
        let curve = ClipComparison.normalizedCurve(metrics())
        #expect(curve.count == ClipComparison.curveResolution + 1)
        #expect(curve.first?.progress == 0)
        #expect(curve.last?.progress == 1)
        #expect(curve.first?.height == 0)
        #expect(curve.last?.height == 1)
    }

    @Test("resampling interpolates between stored samples")
    func resamplingInterpolates() throws {
        let curve = ClipComparison.normalizedCurve(metrics())
        // Halfway through the attempt the stored sample is 0.5, and a quarter is interpolated.
        let middle = try #require(curve.first { abs($0.progress - 0.5) < 0.001 })
        #expect(abs(middle.height - 0.5) < 0.001)
        // The grid is 50 steps, so the nearest points to a quarter are 0.24 and 0.26.
        let lower = try #require(curve.first { abs($0.progress - 0.24) < 0.001 })
        let upper = try #require(curve.first { abs($0.progress - 0.26) < 0.001 })
        #expect(abs(lower.height - 0.24) < 0.001)
        #expect(abs(upper.height - 0.26) < 0.001)
    }

    @Test("a clip with no progress samples yields an empty curve")
    func emptyCurve() throws {
        let curve = ClipComparison.normalizedCurve(metrics(progress: []))
        #expect(curve.isEmpty)
    }
}
