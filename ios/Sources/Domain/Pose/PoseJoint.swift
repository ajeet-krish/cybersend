import Foundation

/// The 19 joints returned by Apple Vision 2D human body pose (`VNDetectHumanBodyPoseRequest`).
///
/// The numeric values are the Vision joint names, so the detector can map them directly without
/// a lookup table in the feature layer. Apple's 3D request uses a different 17 joint set, so this
/// enum is deliberately not shared with any future 3D path.
public enum PoseJoint: String, CaseIterable, Codable, Sendable {
    case nose
    case leftEye
    case rightEye
    case leftEar
    case rightEar
    case neck
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle
    case root

    /// Joints the metrics layer trusts enough to gate a frame on. Face points and elbows are
    /// excluded because they are the joints Vision loses first under occlusion, and a metrics
    /// frame that only sees a face is not a usable climbing frame.
    public static let core: [PoseJoint] = [
        .neck,
        .leftShoulder, .rightShoulder,
        .leftWrist, .rightWrist,
        .leftHip, .rightHip,
        .leftKnee, .rightKnee,
        .leftAnkle, .rightAnkle,
        .root,
    ]

    /// Joints used for the vertical progress signal. The midpoint of these four is the body
    /// centroid (docs/decisions.md, 2026-10-21 Phase 5 record).
    public static let centroid: [PoseJoint] = [
        .leftShoulder, .rightShoulder, .leftHip, .rightHip,
    ]
}
