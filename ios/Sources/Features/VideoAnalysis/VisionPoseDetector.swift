import CyberSendDomain
import CoreVideo
import Foundation
import ImageIO
import Vision

/// Apple Vision 2D human body pose adapter.
///
/// No model file, no conversion, no quantization. `VNDetectHumanBodyPoseRequest` ships with the
/// OS, runs on the Neural Engine where the OS decides it is appropriate, and returns 19 named
/// joints plus a per observation confidence.
public final class VisionPoseDetector: PoseDetecting {
    private let handler = VNSequenceRequestHandler()
    private let request = VNDetectHumanBodyPoseRequest()

    public init() {}

    public var revision: Int { request.revision }

    public func detect(
        on pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> [PoseObservation] {
        do {
            try handler.perform([request], on: pixelBuffer, orientation: orientation)
        } catch {
            throw PoseAnalysisError.detectionFailed(error.localizedDescription)
        }

        guard let results = request.results, !results.isEmpty else { return [] }
        return results.map(Self.observation(from:))
    }

    /// Converts one Vision observation into the Domain shape.
    ///
    /// Vision reports normalized coordinates with a bottom left origin. The Domain uses a top
    /// left origin, matching the canvas coordinate contract, so y is flipped exactly once here
    /// and nowhere else.
    static func observation(from result: VNHumanBodyPoseObservation) -> PoseObservation {
        let recognized = (try? result.recognizedPoints(.all)) ?? [:]
        var joints: [PoseJoint: JointSample] = [:]
        joints.reserveCapacity(recognized.count)

        for (name, point) in recognized {
            guard let joint = map(name) else { continue }
            joints[joint] = JointSample(
                x: Double(point.location.x),
                y: 1 - Double(point.location.y),
                confidence: Double(point.confidence)
            )
        }

        let boundingBox = Self.boundingBox(of: Array(joints.values))

        return PoseObservation(
            joints: joints,
            confidence: Double(result.confidence),
            boundingBox: boundingBox
        )
    }

    /// Normalized box that contains every detected joint.
    ///
    /// `VNHumanBodyPoseObservation` carries no bounding box of its own (unlike detection
    /// observations), so it is derived here. Used only for deterministic subject ordering.
    static func boundingBox(of samples: [JointSample]) -> PoseRect {
        var minX = 1.0
        var minY = 1.0
        var maxX = 0.0
        var maxY = 0.0
        var found = false

        for sample in samples where sample.confidence > 0 {
            found = true
            minX = min(minX, sample.x)
            maxX = max(maxX, sample.x)
            minY = min(minY, sample.y)
            maxY = max(maxY, sample.y)
        }

        guard found else { return PoseRect(x: 0, y: 0, width: 0, height: 0) }
        return PoseRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    static func map(_ name: VNHumanBodyPoseObservation.JointName) -> PoseJoint? {
        switch name {
        case .nose: return .nose
        case .leftEye: return .leftEye
        case .rightEye: return .rightEye
        case .leftEar: return .leftEar
        case .rightEar: return .rightEar
        case .neck: return .neck
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        case .leftHip: return .leftHip
        case .rightHip: return .rightHip
        case .leftKnee: return .leftKnee
        case .rightKnee: return .rightKnee
        case .leftAnkle: return .leftAnkle
        case .rightAnkle: return .rightAnkle
        case .root: return .root
        default: return nil
        }
    }
}
