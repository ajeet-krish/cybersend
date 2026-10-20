import Foundation

/// Video entity plus pose and retention enums (port of src/domain/models/video.ts). Pose
/// extraction and retention enforcement arrive with phase 5; the schema and types exist from
/// phase 1 so export and backup cover them.
public enum PoseStatus: String, Codable, CaseIterable, Sendable {
    case none
    case pending
    case running
    case done
    case failed
}

public enum RetentionClass: String, Codable, CaseIterable, Sendable {
    case ephemeral
    case keep
}

public let poseStatuses: [PoseStatus] = [.none, .pending, .running, .done, .failed]
public let retentionClasses: [RetentionClass] = [.ephemeral, .keep]

public struct Video: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var sessionId: String?
    public var climbId: String?
    public var uri: String
    public var width: Int?
    public var height: Int?
    public var durationMs: Int?
    public var fps: Double?
    public var poseStatus: PoseStatus
    public var retentionClass: RetentionClass
    public let createdAt: String

    public init(
        id: String,
        sessionId: String? = nil,
        climbId: String? = nil,
        uri: String,
        width: Int? = nil,
        height: Int? = nil,
        durationMs: Int? = nil,
        fps: Double? = nil,
        poseStatus: PoseStatus = .none,
        retentionClass: RetentionClass = .ephemeral,
        createdAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.climbId = climbId
        self.uri = uri
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.fps = fps
        self.poseStatus = poseStatus
        self.retentionClass = retentionClass
        self.createdAt = createdAt
    }
}

public struct PoseKeypoint: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let videoId: String
    public var tMs: Int
    public var score: Double?
    /// Flat normalized keypoint array. Encoding lands with the phase 5 pose pipeline.
    public var keypointsJson: String

    public init(id: String, videoId: String, tMs: Int, score: Double? = nil, keypointsJson: String) {
        self.id = id
        self.videoId = videoId
        self.tMs = tMs
        self.score = score
        self.keypointsJson = keypointsJson
    }
}
