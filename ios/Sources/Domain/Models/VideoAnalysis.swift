import Foundation

/// How stable the camera was during a clip.
///
/// Classification gates what the app is allowed to claim: a static clip supports metric
/// comparison and spatial side by side, a handheld clip supports relative metrics only
/// (docs/decisions.md, 2026-10-21 Phase 5 record). Handheld footage has no shared coordinate
/// frame, so comparing two such clips pixel for pixel would be meaningless.
public enum CameraStabilityClass: String, Codable, CaseIterable, Sendable {
    /// Tripod, wall mount, or a phone that did not move. Raw value stays "static" for rows.
    case stationary = "static"
    case nearStatic = "near_static"
    case handheld

    public var supportsComparison: Bool {
        self != .handheld
    }

    public var supportsSpatialOverlay: Bool {
        self == .stationary
    }
}

/// Discrete things that happened during an attempt. Tier A and Tier B metrics in
/// docs/architecture.md, Pose Pipeline section.
public enum AnalysisEventType: String, Codable, CaseIterable, Sendable {
    case attemptStart = "attempt_start"
    case attemptEnd = "attempt_end"
    case fall
    case dyno
    case cutFeet = "cut_feet"
    case rest
}

/// One completed analysis of one clip.
///
/// The pose track is stored separately (`PoseTrackCodec`) and is deliberately absent from the
/// export payload, so `trackBlob` can be nil after a restore. Callers treat nil as "recompute
/// needed" rather than as corruption.
public struct VideoAnalysis: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let videoId: String
    /// Bumped whenever the metrics maths or thresholds change, so old analyses are visibly stale.
    public var algorithmVersion: Int
    /// Vision request revision at analysis time. An OS update can change keypoints.
    public var visionRevision: Int
    public var samplingHz: Double
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var sourceFPS: Double?
    public var cameraClass: CameraStabilityClass
    public var coverage: Double
    public var trackFormat: String?
    public var trackBlob: Data?
    public var qualityFlags: String
    public let createdAt: String

    public init(
        id: String,
        videoId: String,
        algorithmVersion: Int,
        visionRevision: Int,
        samplingHz: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFPS: Double? = nil,
        cameraClass: CameraStabilityClass,
        coverage: Double,
        trackFormat: String? = nil,
        trackBlob: Data? = nil,
        qualityFlags: String = "",
        createdAt: String
    ) {
        self.id = id
        self.videoId = videoId
        self.algorithmVersion = algorithmVersion
        self.visionRevision = visionRevision
        self.samplingHz = samplingHz
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sourceFPS = sourceFPS
        self.cameraClass = cameraClass
        self.coverage = coverage
        self.trackFormat = trackFormat
        self.trackBlob = trackBlob
        self.qualityFlags = qualityFlags
        self.createdAt = createdAt
    }

    public var needsRecompute: Bool {
        trackBlob == nil
    }
}

/// One event inside an analysis, positioned in clip time.
public struct AnalysisEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let analysisId: String
    public var type: AnalysisEventType
    public var startMs: Int
    public var endMs: Int?
    /// Set for events that belong to one joint (a fall is the centroid, a dyno is a hand).
    public var joint: PoseJoint?
    public var xNorm: Double?
    public var yNorm: Double?
    public var value: Double?
    public var confidence: Double

    public init(
        id: String,
        analysisId: String,
        type: AnalysisEventType,
        startMs: Int,
        endMs: Int? = nil,
        joint: PoseJoint? = nil,
        xNorm: Double? = nil,
        yNorm: Double? = nil,
        value: Double? = nil,
        confidence: Double
    ) {
        self.id = id
        self.analysisId = analysisId
        self.type = type
        self.startMs = startMs
        self.endMs = endMs
        self.joint = joint
        self.xNorm = xNorm
        self.yNorm = yNorm
        self.value = value
        self.confidence = confidence
    }

    public var durationMs: Int? {
        guard let endMs else { return nil }
        return max(0, endMs - startMs)
    }
}
