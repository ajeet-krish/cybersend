import Foundation
import Testing
@testable import CyberSendDomain

// Tier B (P6): dyno, cut feet, and rest, all pose only. Every fixture is synthetic and every
// threshold is a hypothesis, so these tests prove the detectors fire on the intended shape and
// stay quiet on the shapes they must not confuse, not that the numbers match a real climber.

private func limbFrame(
    tMs: Int,
    centroidY: Double = 0.45,
    ankleLift: Double = 0,
    rightWrist: (dx: Double, dy: Double) = (0, 0)
) -> PoseFrame {
    var joints: [PoseJoint: JointSample] = [:]
    func put(_ joint: PoseJoint, _ x: Double, _ y: Double) {
        joints[joint] = JointSample(x: x, y: y, confidence: 0.95)
    }
    put(.nose, 0.50, centroidY - 0.18)
    put(.neck, 0.50, centroidY - 0.12)
    put(.leftShoulder, 0.45, centroidY - 0.10)
    put(.rightShoulder, 0.55, centroidY - 0.10)
    put(.leftHip, 0.47, centroidY + 0.02)
    put(.rightHip, 0.53, centroidY + 0.02)
    put(.root, 0.50, centroidY + 0.02)
    put(.leftWrist, 0.42, centroidY - 0.05)
    put(.rightWrist, 0.58 + rightWrist.dx, centroidY - 0.05 + rightWrist.dy)
    put(.leftKnee, 0.47, centroidY + 0.22)
    put(.rightKnee, 0.53, centroidY + 0.22)
    put(.leftAnkle, 0.47, centroidY + 0.35 - ankleLift)
    put(.rightAnkle, 0.53, centroidY + 0.35 - ankleLift)
    return PoseFrame(tMs: tMs, joints: joints)
}

private func track(_ frames: [PoseFrame], hz: Double = 30) -> PoseTrack {
    PoseTrack(
        samplingHz: hz,
        sourceWidth: 1080,
        sourceHeight: 1920,
        sourceFPS: hz,
        visionRevision: 3,
        frames: frames
    )
}

private func frames(
    seconds: Double,
    hz: Double = 30,
    _ body: (Double) -> PoseFrame
) -> [PoseFrame] {
    let count = Int((seconds * hz).rounded())
    return (0..<count).map { index in
        let time = Double(index) / hz
        return body(time)
    }
}

@Suite("Tier B dyno")
struct TierBDynoTests {
    @Test("a fast hand throw is reported as a dyno on that wrist")
    func fastHandThrow() throws {
        // Still for a second, the right wrist travels 0.4 normalized in 0.35 s, then still.
        let clip = track(frames(seconds: 2.0) { time in
            let progress = min(1, max(0, (time - 1.0) / 0.35))
            return limbFrame(
                tMs: Int((time * 1000).rounded()),
                rightWrist: (dx: 0.4 * progress, dy: -0.1 * progress)
            )
        })
        let metrics = try #require(TierAMetricsEngine.compute(track: clip))

        #expect(metrics.dynoEvents.count == 1)
        let dyno = try #require(metrics.dynoEvents.first)
        #expect(dyno.type == .dyno)
        #expect(dyno.joint == .rightWrist)
        #expect(dyno.confidence > 0)
        #expect(metrics.events.contains { $0.type == .dyno })
    }

    @Test("a slow hand move over the same distance is not a dyno")
    func slowHandMove() throws {
        let clip = track(frames(seconds: 3.0) { time in
            let progress = min(1, max(0, (time - 1.0) / 1.5))
            return limbFrame(
                tMs: Int((time * 1000).rounded()),
                rightWrist: (dx: 0.4 * progress, dy: -0.1 * progress)
            )
        })
        let metrics = try #require(TierAMetricsEngine.compute(track: clip))
        #expect(metrics.dynoEvents.isEmpty)
    }

    @Test("a hand that darts out and back is not a dyno")
    func noNetTravel() throws {
        // Fast out and back inside 0.2 s: the speed peak is real, the travel across the window
        // is not, because the hand ends where it started.
        let clip = track(frames(seconds: 2.0) { time in
            let out = min(1, max(0, (time - 1.0) / 0.1))
            let back = min(1, max(0, (time - 1.1) / 0.1))
            return limbFrame(
                tMs: Int((time * 1000).rounded()),
                rightWrist: (dx: 0.35 * (out - back), dy: 0)
            )
        })
        let metrics = try #require(TierAMetricsEngine.compute(track: clip))
        #expect(metrics.dynoEvents.isEmpty)
    }
}

@Suite("Tier B cut feet")
struct TierBCutFeetTests {
    @Test("both ankles rising toward the hips with a still body is cut feet")
    func anklesRise() throws {
        // Hips fixed, ankles lift 0.2 normalized (about 0.38 body heights) over half a second.
        let clip = track(frames(seconds: 2.0) { time in
            let lift = min(0.2, max(0, (time - 1.0) * 0.4))
            return limbFrame(
                tMs: Int((time * 1000).rounded()),
                ankleLift: lift
            )
        })
        let metrics = try #require(TierAMetricsEngine.compute(track: clip))

        #expect(metrics.cutFeetEvents.count == 1)
        let event = try #require(metrics.cutFeetEvents.first)
        #expect(event.type == .cutFeet)
        #expect(event.endMs != nil)
        #expect(event.confidence > 0)
    }

    @Test("a high step where the whole body rises is not cut feet")
    func bodyRiseIsNotCutFeet() throws {
        // The ankles and the body rise together: the ankles never close on the hips.
        let clip = track(frames(seconds: 2.0) { time in
            let rise = min(0.2, max(0, (time - 1.0) * 0.4))
            return limbFrame(
                tMs: Int((time * 1000).rounded()),
                centroidY: 0.45 - rise
            )
        })
        let metrics = try #require(TierAMetricsEngine.compute(track: clip))
        #expect(metrics.cutFeetEvents.isEmpty)
    }

    @Test("one ankle moving alone is not cut feet")
    func oneAnkleIsNotEnough() throws {
        let clip = track(frames(seconds: 2.0) { time in
            let lift = min(0.2, max(0, (time - 1.0) * 0.4))
            var frame = limbFrame(tMs: Int((time * 1000).rounded()), ankleLift: lift)
            // Pin the right ankle where it started, so only the left foot comes up.
            frame.joints[.rightAnkle] = JointSample(x: 0.53, y: 0.80, confidence: 0.95)
            return frame
        })
        let metrics = try #require(TierAMetricsEngine.compute(track: clip))
        #expect(metrics.cutFeetEvents.isEmpty)
    }
}

@Suite("Tier B rest")
struct TierBRestTests {
    @Test("a long still period inside the attempt is a rest")
    func longStillPeriod() throws {
        // Rise for 0.7 s, hold still for 2.5 s, rise again for 0.7 s.
        let clip = track(frames(seconds: 5.0) { time in
            let y: Double
            if time < 0.5 {
                y = 0.55
            } else if time < 1.2 {
                y = 0.55 - (time - 0.5) / 0.7 * 0.2
            } else if time < 3.7 {
                y = 0.35
            } else if time < 4.4 {
                y = 0.35 - (time - 3.7) / 0.7 * 0.15
            } else {
                y = 0.20
            }
            return limbFrame(tMs: Int((time * 1000).rounded()), centroidY: y)
        })
        let metrics = try #require(TierAMetricsEngine.compute(track: clip))

        #expect(metrics.restEvents.count == 1)
        let rest = try #require(metrics.restEvents.first)
        #expect(rest.type == .rest)
        let duration = (rest.endMs ?? rest.startMs) - rest.startMs
        #expect(duration >= 2_000)
        #expect(metrics.events.contains { $0.type == .rest })
    }

    @Test("a short pause is not a rest")
    func shortPause() throws {
        let clip = track(frames(seconds: 4.0) { time in
            let y: Double
            if time < 0.5 {
                y = 0.55
            } else if time < 1.2 {
                y = 0.55 - (time - 0.5) / 0.7 * 0.2
            } else if time < 2.0 {
                y = 0.35
            } else {
                y = 0.35 - (time - 2.0) / 1.0 * 0.15
            }
            return limbFrame(tMs: Int((time * 1000).rounded()), centroidY: y)
        })
        let metrics = try #require(TierAMetricsEngine.compute(track: clip))
        #expect(metrics.restEvents.isEmpty)
    }
}

@Suite("Tier B event ordering")
struct TierBOrderingTests {
    @Test("events at the same millisecond keep a stable order")
    func stableOrder() {
        let order = [
            AnalysisEventType.attemptStart,
            .fall,
            .dyno,
            .cutFeet,
            .rest,
            .attemptEnd,
        ].map { TierAMetricsEngine.eventOrder($0) }
        #expect(order == order.sorted())
        #expect(Set(order).count == order.count, "every type has its own rank")
    }
}
