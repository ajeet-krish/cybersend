import Foundation

/// Orientation of the stored video as reported by the track's preferred transform.
public enum VideoOrientation: String, Codable, Equatable, Sendable {
    case up
    case upMirrored
    case down
    case downMirrored
    case left
    case leftMirrored
    case right
    case rightMirrored

    /// True when the stored frame is rotated by a quarter turn, so display width and height are
    /// the transpose of the encoded pixel dimensions.
    public var swapsDimensions: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored:
            return true
        case .up, .upMirrored, .down, .downMirrored:
            return false
        }
    }

    public var isMirrored: Bool {
        switch self {
        case .upMirrored, .downMirrored, .leftMirrored, .rightMirrored:
            return true
        default:
            return false
        }
    }
}

/// Everything the analysis needs to know about a clip before reading a frame.
public struct VideoMetadata: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var nominalFPS: Double?
    public var durationMs: Int
    public var isHDR: Bool
    public var orientation: VideoOrientation

    public init(
        width: Int,
        height: Int,
        nominalFPS: Double? = nil,
        durationMs: Int,
        isHDR: Bool = false,
        orientation: VideoOrientation = .up
    ) {
        self.width = width
        self.height = height
        self.nominalFPS = nominalFPS
        self.durationMs = durationMs
        self.isHDR = isHDR
        self.orientation = orientation
    }

    /// Long edge of the source after orientation is applied.
    public var longEdge: Int { max(width, height) }
}

/// Sampling policy for the pose pipeline.
///
/// Slow motion clips are 120 or 240 fps, which is four to eight times more frames than the
/// derivative maths needs. The plan caps analysis at 60 Hz and stores at 30 Hz
/// (docs/architecture.md, Pose Pipeline section).
public enum FrameSampling {
    public static let maximumAnalysisFPS: Double = 60

    /// How many decoded frames to skip between analysed frames.
    ///
    /// Never returns less than one. An unknown or unusually low frame rate is analysed frame by
    /// frame, which is the safe default.
    public static func recommendedStride(forFPS fps: Double?) -> Int {
        guard let fps, fps.isFinite, fps > maximumAnalysisFPS else { return 1 }
        let ratio = fps / maximumAnalysisFPS
        return max(1, Int(ratio.rounded(.up)))
    }

    /// Effective analysis rate for a source and stride, useful for progress estimates.
    public static func effectiveFPS(sourceFPS: Double?, stride: Int) -> Double? {
        guard let sourceFPS, sourceFPS.isFinite, sourceFPS > 0, stride > 0 else { return nil }
        return sourceFPS / Double(stride)
    }
}
