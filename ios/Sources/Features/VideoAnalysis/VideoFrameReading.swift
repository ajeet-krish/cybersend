import CyberSendDomain
import CoreVideo
import Foundation
import ImageIO

/// One decoded frame handed to the analysis loop.
///
/// The pixel buffer is valid for the duration of the callback only. Nothing retains it, because
/// the whole pipeline is built to hold one buffer at a time (docs/architecture.md, Pose Pipeline).
public struct DecodedFrame {
    public let pixelBuffer: CVPixelBuffer
    public let tMs: Int
    public let orientation: CGImagePropertyOrientation

    public init(pixelBuffer: CVPixelBuffer, tMs: Int, orientation: CGImagePropertyOrientation) {
        self.pixelBuffer = pixelBuffer
        self.tMs = tMs
        self.orientation = orientation
    }
}

/// Sequential frame source for pose analysis.
///
/// This is a seam, not a convenience: tests supply synthetic sequences on CI where no camera and
/// no asset exist, and a future frame source (live capture, or a different container) can be
/// dropped in without touching the analysis loop.
public protocol VideoFrameReading: AnyObject {
    var metadata: VideoMetadata { get }

    /// Reads frames in order. The callback returns false to stop early.
    ///
    /// `startAfterMs` resumes an interrupted analysis: frames at or before that timestamp are
    /// decoded and skipped so timestamps stay authoritative.
    func read(
        stride: Int,
        startAfterMs: Int?,
        onFrame: (DecodedFrame) throws -> Bool
    ) throws
}
