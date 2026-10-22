import Foundation
import Testing
@testable import CyberSendDomain

// Tier A metrics: attempt window, fall, progress, smoothness, hesitation map, camera class,
// and the body scale estimate. All synthetic, all deterministic, no device needed.

private func bodyFrame(tMs: Int, x: Double, y: Double, confidence: Double = 0.9) -> PoseFrame {
    var joints: [PoseJoint: JointSample] = [:]
    func put(_ joint: PoseJoint, _ px: Double, _ py: Double) {
        joints[joint] = JointSample(x: px, y: py, confidence: confidence)
    }
    put(.nose, x, y - 0.30)
    put(.neck, x, y - 0.20)
    put(.leftShoulder, x - 0.05, y - 0.15)
    put(.rightShoulder, x + 0.05, y - 0.15)
    put(.leftHip, x - 0.04, y + 0.10)
    put(.rightHip, x + 0.04, y + 0.10)
    put(.leftKnee, x - 0.04, y + 0.22)
    put(.rightKnee, x + 0.04, y + 0.22)
    put(.leftAnkle, x - 0.04, y + 0.35)
    put(.rightAnkle, x + 0.04, y + 0.35)
    put(.root, x, y + 0.10)
    return PoseFrame(tMs: tMs, joints: joints)
}

private func makeTrack(
    seconds: Double,
    hz: Double = 30,
    position: (Double) -> (x: Double, y: Double)
) -> PoseTrack {
    let count = max(1, Int(seconds * hz))
    let frames = (0..<count).map { index -> PoseFrame in
        let time = Double(index) / hz
        let point = position(time)
        return bodyFrame(tMs: Int((time * 1000).rounded()), x: point.x, y: point.y)
    }
    return PoseTrack(
        samplingHz: hz,
        sourceWidth: 720,
        sourceHeight: 1280,
        sourceFPS: hz,
        visionRevision: 1,
        frames: frames
    )
}

// MARK: - Body scale

@Test func bodyScaleUsesHeadToAnkleSpanWhenVisible() throws {
    let track = makeTrack(seconds: 3) { _ in (0.5, 0.5) }
    let prepared = try #require(TrackPreparation.prepare(track))

    #expect(abs(prepared.bodyScale.medianBodyHeight - 0.65) < 1e-9)
    #expect(prepared.bodyScale.usedFallback == false)
    #expect(prepared.bodyScale.isReliable)
    #expect(prepared.bodyScale.relativeSpread == 0)
}

@Test func bodyScaleFallsBackToTorsoWhenAnklesAreMissing() throws {
    let count = 90
    let frames = (0..<count).map { index -> PoseFrame in
        var frame = bodyFrame(tMs: index * 33, x: 0.5, y: 0.5)
        frame.joints[.leftAnkle] = nil
        frame.joints[.rightAnkle] = nil
        frame.joints[.nose] = nil
        frame.coverage = PoseFrame.computeCoverage(frame.joints)
        return frame
    }
    let track = PoseTrack(
        samplingHz: 30,
        sourceWidth: 720,
        sourceHeight: 1280,
        visionRevision: 1,
        frames: frames
    )
    let prepared = try #require(TrackPreparation.prepare(track))

    #expect(prepared.bodyScale.usedFallback)
    #expect(prepared.bodyScale.isReliable == false)
    // Shoulder midpoint to hip midpoint is 0.25, times the anthropometric factor 3.
    #expect(abs(prepared.bodyScale.medianBodyHeight - 0.75) < 1e-9)
    #expect(prepared.warnings.contains { $0.contains("torso") })
}

@Test func twoFramesAreNotEnoughForMetrics() {
    let frames = [bodyFrame(tMs: 0, x: 0.5, y: 0.5), bodyFrame(tMs: 33, x: 0.5, y: 0.5)]
    let track = PoseTrack(
        samplingHz: 30,
        sourceWidth: 720,
        sourceHeight: 1280,
        visionRevision: 1,
        frames: frames
    )
    #expect(TrackPreparation.prepare(track) == nil)
    #expect(TierAMetricsEngine.compute(track: track) == nil)
}

// MARK: - Camera class

@Test func cameraClassSeparatesStillAndDriftingClips() throws {
    let still = makeTrack(seconds: 4) { _ in (0.5, 0.5) }
    let drifting = makeTrack(seconds: 4) { time in (0.2 + time * 0.09, 0.5) }
    let wobbling = makeTrack(seconds: 4) { time in (0.2 + time * 0.3, 0.5) }

    let stillMetrics = try #require(TierAMetricsEngine.compute(track: still))
    let driftingMetrics = try #require(TierAMetricsEngine.compute(track: drifting))
    let wobblingMetrics = try #require(TierAMetricsEngine.compute(track: wobbling))

    #expect(stillMetrics.cameraClass == .stationary)
    #expect(driftingMetrics.cameraClass == .nearStatic)
    #expect(wobblingMetrics.cameraClass == .handheld)
    #expect(wobblingMetrics.warnings.contains { $0.contains("Handheld") })
}

// MARK: - Attempt window and fall

@Test func riseAndFallProducesAnAttemptWindowAndAFall() throws {
    let track = makeTrack(seconds: 4.5) { time in
        if time < 1.0 { return (0.5, 0.75) }
        if time < 2.5 { return (0.5, 0.75 - (time - 1.0) / 1.5 * 0.5) }
        if time < 3.0 { return (0.5, 0.25) }
        if time < 3.4 { return (0.5, 0.25 + (time - 3.0) / 0.4 * 0.5) }
        return (0.5, 0.75)
    }

    let metrics = try #require(TierAMetricsEngine.compute(track: track))

    #expect(metrics.attemptWindow.detectedByMotion)
    #expect(metrics.attemptWindow.startMs >= 900)
    #expect(metrics.attemptWindow.startMs <= 1400)

    let fall = try #require(metrics.fallEvents.first)
    #expect(fall.startMs >= 2900)
    #expect(fall.startMs <= 3300)
    #expect(fall.confidence > 0.5)

    // The attempt ends where the fall begins.
    #expect(abs(metrics.attemptWindow.endMs - fall.startMs) <= 40)

    // 0.5 normalized units of travel over a 0.65 body height, so about 0.77 body heights.
    let highest = try #require(metrics.highestPoint)
    #expect(abs(highest.value - 0.77) < 0.08)
    #expect(metrics.progress.count > 5)
    #expect(metrics.progress.count < 40, "progress is decimated to the 10 Hz curve rate")
    #expect(metrics.peakSpeed ?? 0 > 0.3)
    #expect(metrics.isUsable)
}

@Test func aStationaryClipIsNotAnAttempt() throws {
    let track = makeTrack(seconds: 4) { _ in (0.5, 0.5) }
    let metrics = try #require(TierAMetricsEngine.compute(track: track))

    #expect(metrics.attemptWindow.detectedByMotion == false)
    #expect(metrics.attemptWindow.confidence < 0.4)
    #expect(metrics.fallEvents.isEmpty)
    #expect(metrics.isUsable == false)
    #expect(metrics.warnings.contains { $0.contains("No movement") })
}

// MARK: - Progress curve

@Test func progressCurveRisesAndFallsWithTheClimber() throws {
    let track = makeTrack(seconds: 4.0) { time in
        if time < 1.0 { return (0.5, 0.7) }
        if time < 2.0 { return (0.5, 0.7 - (time - 1.0) * 0.4) }
        if time < 3.0 { return (0.5, 0.3) }
        return (0.5, 0.7)
    }
    let metrics = try #require(TierAMetricsEngine.compute(track: track))

    let highest = try #require(metrics.highestPoint)
    #expect(abs(highest.value - 0.4 / 0.65) < 0.05)
    #expect((metrics.progress.first?.value ?? 1) < highest.value)
    // The attempt ends where the fall begins, so the curve ends at the top.
    let last = try #require(metrics.progress.last)
    #expect(abs(last.value - highest.value) < 0.05)

    let times = metrics.progress.map(\.tMs)
    #expect(times == times.sorted())
}

// MARK: - Smoothness

@Test func aStraightPathScoresSmootherThanAZigzag() throws {
    let straight = makeTrack(seconds: 4) { time in
        let progress = min(1, time / 2)
        return (0.3 + progress * 0.4, 0.5)
    }
    let zigzag = makeTrack(seconds: 4) { time in
        let progress = min(1, time / 2)
        let wobble = 0.06 * sin(2 * Double.pi * 2 * time)
        return (0.3 + progress * 0.4 + wobble, 0.5 + wobble)
    }

    let straightPrepared = try #require(TrackPreparation.prepare(straight))
    let zigzagPrepared = try #require(TrackPreparation.prepare(zigzag))

    let straightScore = try #require(
        TierAMetricsEngine.smoothness(
            straightPrepared,
            range: 0..<(straightPrepared.sampleCount / 2),
            thresholds: MetricThresholds()
        )
    )
    let zigzagScore = try #require(
        TierAMetricsEngine.smoothness(
            zigzagPrepared,
            range: 0..<(zigzagPrepared.sampleCount / 2),
            thresholds: MetricThresholds()
        )
    )

    #expect(straightScore.logDimensionlessJerk > zigzagScore.logDimensionlessJerk)
    #expect(straightScore.pathEfficiency > zigzagScore.pathEfficiency)
}

// MARK: - Hesitation map

@Test func hesitationMapConcentratesWhereTheClimberPauses() throws {
    // The pause has to happen above the ground band, otherwise the quiet-end rule would end the
    // attempt during the pause, which is correct behaviour and not what this test measures.
    let track = makeTrack(seconds: 4.5) { time in
        if time < 0.5 { return (0.3, 0.8) }
        if time < 1.5 { return (0.3, 0.8 - (time - 0.5) * 0.3) }
        if time < 3.5 { return (0.3, 0.5) }
        if time < 4.0 { return (0.3 + (time - 3.5) * 0.6, 0.5 - (time - 3.5) * 0.4) }
        return (0.6, 0.3)
    }
    let metrics = try #require(TierAMetricsEngine.compute(track: track))
    let map = try #require(metrics.hesitation)

    #expect(map.columns == 24)
    #expect(map.rows == 32)
    #expect(map.weights.count == 24 * 32)

    let peakIndex = try #require(map.weights.indices.max(by: { map.weights[$0] < map.weights[$1] }))
    let column = peakIndex % map.columns
    #expect(column == Int(0.3 * 24), "the long pause happens at x = 0.3")
    #expect(map.peakDwellMs > 1000)
}

// MARK: - Determinism and versioning

@Test func metricsRecordTheirVersionsAndAreDeterministic() throws {
    let track = makeTrack(seconds: 3) { time in
        (0.5, 0.7 - min(1, time / 2) * 0.3)
    }
    let first = try #require(TierAMetricsEngine.compute(track: track))
    let second = try #require(TierAMetricsEngine.compute(track: track))

    #expect(first == second)
    #expect(first.algorithmVersion == TierAMetricsEngine.algorithmVersion)
    #expect(first.thresholdsVersion == MetricThresholds().version)
    #expect(first.quality > 0.5)
}
