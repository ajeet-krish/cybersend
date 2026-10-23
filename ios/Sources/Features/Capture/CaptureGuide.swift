import Foundation

// Guided capture helpers (P4). Everything here is pure so the rules can be tested without a
// camera: which format to pick, when the phone counts as level, how the recording clock reads,
// and where the framing box sits. The AVFoundation plumbing lives in VideoRecorder.swift.

/// Gravity in device coordinates, as CoreMotion reports it. Device axes: x right, y up along the
/// screen, z out of the screen toward the viewer.
public struct GravityVector: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// How far the phone is rotated around the viewing axis, which is what "is the horizon level"
/// means for a camera pointed at a wall.
public struct CaptureLevel: Equatable, Sendable {
    /// Zero when the phone is upright in the filming orientation. Positive means the top of the
    /// phone has rolled to the right of the subject (the right edge is low).
    public var rollDegrees: Double

    /// Two degrees is tighter than a person can hold by hand for long and loose enough that the
    /// badge can actually turn green. Confirmed as usable (or not) in dogfood.
    public static let levelToleranceDegrees: Double = 2

    public init(rollDegrees: Double) {
        self.rollDegrees = rollDegrees
    }

    /// Roll computed from gravity. The projection onto the x axis is the sideways tilt, so a
    /// phone held upright reads zero regardless of which way it is facing.
    public init(gravity: GravityVector) {
        let vertical = -gravity.y
        let magnitude = (gravity.x * gravity.x + vertical * vertical).squareRoot()
        guard magnitude > 1e-6 else {
            self.rollDegrees = 0
            return
        }
        self.rollDegrees = atan2(gravity.x, vertical) * 180 / Double.pi
    }

    public var isLevel: Bool {
        abs(rollDegrees) <= Self.levelToleranceDegrees
    }

    /// What the badge tells the user to do next.
    public var guidance: CaptureGuidance {
        if isLevel { return .level }
        if rollDegrees < 0 { return .rollLeft(degrees: abs(rollDegrees)) }
        return .rollRight(degrees: abs(rollDegrees))
    }
}

public enum CaptureGuidance: Equatable, Sendable {
    case level
    case rollLeft(degrees: Double)
    case rollRight(degrees: Double)

    /// Short label for the level badge. Degrees are rounded to whole numbers because the badge
    /// only needs to be readable at arm's length.
    public var text: String {
        switch self {
        case .level:
            return "Level"
        case .rollLeft(let degrees):
            return "Rotate right \(Int(degrees.rounded())) degrees"
        case .rollRight(let degrees):
            return "Rotate left \(Int(degrees.rounded())) degrees"
        }
    }
}

/// One capture format, reduced to the numbers the selection rules need.
public struct CaptureFormat: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var maxFrameRate: Double

    public init(width: Int, height: Int, maxFrameRate: Double) {
        self.width = width
        self.height = height
        self.maxFrameRate = maxFrameRate
    }

    public var shortEdge: Int { min(width, height) }
    public var longEdge: Int { max(width, height) }
}

/// Format choice for the recorder.
///
/// 1080p60 is the target because 60 fps gives the attempt and fall detectors enough samples to
/// find a boundary, and 1080p is more than the 720 px analysis path consumes, so a larger format
/// only costs storage. 4K is never preferred: the analysis downscales it and the clip is kept.
public enum CaptureFormatSelection {
    public static let targetShortEdge = 1080
    public static let preferredFPS: Double = 60
    public static let minimumFPS: Double = 30
    public static let floorShortEdge = 720

    /// The index of the best format, or nil when nothing on the device is usable.
    ///
    /// Tiers first (60 fps at 1080p, then 30 fps at 1080p, then anything at 720p or better), then
    /// the smallest resolution that clears the tier, then the highest frame rate. Smallest first
    /// is deliberate: every extra pixel is stored on the device and thrown away by Vision.
    public static func bestIndex(in formats: [CaptureFormat]) -> Int? {
        guard !formats.isEmpty else { return nil }

        func tier(_ format: CaptureFormat) -> Int {
            guard format.maxFrameRate >= minimumFPS, format.shortEdge >= floorShortEdge else { return -1 }
            if format.shortEdge >= targetShortEdge {
                return format.maxFrameRate >= preferredFPS ? 2 : 1
            }
            return 0
        }

        let ranked = formats.enumerated()
            .filter { tier($0.element) >= 0 }
            .sorted { lhs, rhs in
                let leftTier = tier(lhs.element)
                let rightTier = tier(rhs.element)
                if leftTier != rightTier { return leftTier > rightTier }
                if lhs.element.shortEdge != rhs.element.shortEdge {
                    return lhs.element.shortEdge < rhs.element.shortEdge
                }
                if lhs.element.maxFrameRate != rhs.element.maxFrameRate {
                    return lhs.element.maxFrameRate > rhs.element.maxFrameRate
                }
                if lhs.element.longEdge != rhs.element.longEdge {
                    return lhs.element.longEdge < rhs.element.longEdge
                }
                return lhs.offset < rhs.offset
            }

        return ranked.first?.offset
    }
}

/// Where the framing guide sits, normalized over the preview.
public struct CaptureFramingBox: Equatable, Sendable {
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

    /// Tall and narrow: a climber standing at the wall with both feet visible occupies roughly
    /// this much of a portrait frame, and the top margin leaves room for the finishing hold.
    public static let standard = CaptureFramingBox(x: 0.22, y: 0.10, width: 0.56, height: 0.80)

    public var isInsideUnitSquare: Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1 && y + height <= 1
    }
}

public enum CaptureLimits {
    /// The badge starts warning here. A boulder attempt is well under a minute.
    public static let softWarningMs = 60_000
    /// The UI stops recording here.
    public static let maximumRecordingMs = 90_000
    /// The movie output's own stop, five seconds later than the UI. If the UI ever stops
    /// updating, the output still ends the recording instead of filling the phone.
    public static let hardStopMs = maximumRecordingMs + 5_000
}

public enum CaptureDuration {
    /// "0:07", "1:23". Hours are not expected and are formatted as minutes past 60.
    public static func text(milliseconds: Int) -> String {
        let clamped = max(0, milliseconds)
        let totalSeconds = clamped / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    public static func elapsedText(milliseconds: Int) -> String {
        "\(text(milliseconds: milliseconds)) / \(text(milliseconds: CaptureLimits.maximumRecordingMs))"
    }

    public static func isPastSoftWarning(milliseconds: Int) -> Bool {
        milliseconds >= CaptureLimits.softWarningMs
    }
}
