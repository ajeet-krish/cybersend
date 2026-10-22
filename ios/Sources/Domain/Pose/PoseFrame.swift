import Foundation

/// One joint position in normalized image space.
///
/// Coordinates use a top left origin with y growing downward, matching the canvas coordinate
/// contract used by photo tagging. Vision reports a bottom left origin, so the detector adapter
/// flips y once at the boundary and every layer above this type works in one convention.
public struct JointSample: Codable, Equatable, Sendable {
    /// Confidence below which a joint is treated as absent rather than as a weak estimate.
    public static let minimumUsableConfidence: Double = 0.3

    public var x: Double
    public var y: Double
    public var confidence: Double
    /// True when the value was filled in by gap filling rather than observed. Interpolated
    /// samples are allowed to draw a skeleton but never contribute to a metric on their own.
    public var isInterpolated: Bool

    public init(x: Double, y: Double, confidence: Double, isInterpolated: Bool = false) {
        self.x = x
        self.y = y
        self.confidence = confidence
        self.isInterpolated = isInterpolated
    }

    public var isUsable: Bool {
        confidence >= Self.minimumUsableConfidence && !isInterpolated
    }
}

/// One analysed frame. `tMs` is the presentation timestamp, never a frame index, because slow
/// motion sources are strided and frame indices become meaningless.
public struct PoseFrame: Codable, Equatable, Sendable {
    public var tMs: Int
    public var joints: [PoseJoint: JointSample]
    /// Fraction of `PoseJoint.core` present in this frame, 0 to 1.
    public var coverage: Double

    public init(tMs: Int, joints: [PoseJoint: JointSample], coverage: Double? = nil) {
        self.tMs = tMs
        self.joints = joints
        self.coverage = coverage ?? Self.computeCoverage(joints)
    }

    public static func computeCoverage(_ joints: [PoseJoint: JointSample]) -> Double {
        guard !PoseJoint.core.isEmpty else { return 0 }
        let present = PoseJoint.core.reduce(into: 0) { count, joint in
            if joints[joint]?.isUsable == true { count += 1 }
        }
        return Double(present) / Double(PoseJoint.core.count)
    }

    public var isUsable: Bool {
        coverage >= PoseFrame.minimumUsableCoverage
    }

    /// A frame needs roughly half of the core joints before any metric derived from it means
    /// anything. Below this the frame is retained for drawing but excluded from metrics.
    public static let minimumUsableCoverage: Double = 0.5
}

/// A full pose track for one analysed clip.
public struct PoseTrack: Codable, Equatable, Sendable {
    public var samplingHz: Double
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var sourceFPS: Double?
    public var visionRevision: Int
    public var frames: [PoseFrame]

    public init(
        samplingHz: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFPS: Double? = nil,
        visionRevision: Int,
        frames: [PoseFrame]
    ) {
        self.samplingHz = samplingHz
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sourceFPS = sourceFPS
        self.visionRevision = visionRevision
        self.frames = frames
    }

    public var isEmpty: Bool { frames.isEmpty }

    public var durationMs: Int {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return max(0, last.tMs - first.tMs)
    }

    public var usableFrames: [PoseFrame] {
        frames.filter(\.isUsable)
    }

    /// Median confidence over every usable sample, a single number for the review header.
    public func medianConfidence() -> Double {
        let values = frames.flatMap { frame in
            frame.joints.values.filter(\.isUsable).map(\.confidence)
        }.sorted()
        guard !values.isEmpty else { return 0 }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}
