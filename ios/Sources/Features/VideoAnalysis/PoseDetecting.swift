import CyberSendDomain
import CoreVideo
import Foundation
import ImageIO

/// Pose detector seam.
///
/// The protocol exists so the metrics pipeline never imports Vision and so a Core ML pose model
/// can replace Vision later without touching the analysis loop. Instances are confined to one
/// analysis scope (the analysis actor creates and disposes them), which is why the type is not
/// `Sendable`: VNSequenceRequestHandler is not safe to share.
public protocol PoseDetecting: AnyObject {
    /// The Vision model revision in use. Recorded on every analysis so an OS update that changes
    /// keypoints cannot silently mix incomparable tracks.
    var revision: Int { get }

    func detect(
        on pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> [PoseObservation]
}
