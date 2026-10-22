import Foundation

/// One person detected in one frame, expressed without any Vision types.
public struct PoseObservation: Equatable, Sendable {
    public var joints: [PoseJoint: JointSample]
    /// Vision's confidence for the observation as a whole.
    public var confidence: Double
    /// Normalized bounding box (x, y, width, height) with a top left origin, used only to pick
    /// and track a subject. Not a metric input.
    public var boundingBox: PoseRect

    public init(
        joints: [PoseJoint: JointSample],
        confidence: Double,
        boundingBox: PoseRect
    ) {
        self.joints = joints
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// Normalized rectangle with a top left origin.
public struct PoseRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { max(0, width) * max(0, height) }

    public var center: (x: Double, y: Double) {
        (x + width / 2, y + height / 2)
    }
}

/// Deterministic subject ordering for multi person frames.
///
/// Largest bounding box first, then highest observation confidence. The plan (docs/decisions.md,
/// 2026-10-21) says never guess the subject silently, so this order is only a stable tie break for
/// the analysis layer; the review UI still lets the user pick a different subject.
public enum PoseObservationOrdering {
    public static func sorted(_ observations: [PoseObservation]) -> [PoseObservation] {
        observations.sorted { lhs, rhs in
            if lhs.boundingBox.area != rhs.boundingBox.area {
                return lhs.boundingBox.area > rhs.boundingBox.area
            }
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            // Stable final tie break so two frames with equal geometry never flip order.
            return lhs.boundingBox.x < rhs.boundingBox.x
        }
    }
}
