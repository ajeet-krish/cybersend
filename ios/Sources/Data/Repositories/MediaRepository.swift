import CyberSendDomain
import Foundation
import GRDB

// Media repository: photos, videos, and pose keypoint rows (port of
// src/data/repositories/media_repository.ts). Capture and tagging flows arrive in phase 2 and
// phase 5; the repository exists from phase 1 so backup export covers every table.

public struct CreatePhotoInput: Equatable, Sendable {
    public var uri: String
    public var width: Int
    public var height: Int
    public var climbId: String?
    public var sessionId: String?
    public var thumbUri: String?
    public var source: PhotoSource
    public var capturedAt: String?

    public init(
        uri: String,
        width: Int,
        height: Int,
        climbId: String? = nil,
        sessionId: String? = nil,
        thumbUri: String? = nil,
        source: PhotoSource = .camera,
        capturedAt: String? = nil
    ) {
        self.uri = uri
        self.width = width
        self.height = height
        self.climbId = climbId
        self.sessionId = sessionId
        self.thumbUri = thumbUri
        self.source = source
        self.capturedAt = capturedAt
    }
}

public struct CreateVideoInput: Equatable, Sendable {
    public var uri: String
    public var sessionId: String?
    public var climbId: String?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int?
    public var fps: Double?
    public var poseStatus: PoseStatus
    public var retentionClass: RetentionClass

    public init(
        uri: String,
        sessionId: String? = nil,
        climbId: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationMs: Int? = nil,
        fps: Double? = nil,
        poseStatus: PoseStatus = .none,
        retentionClass: RetentionClass = .ephemeral
    ) {
        self.uri = uri
        self.sessionId = sessionId
        self.climbId = climbId
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.fps = fps
        self.poseStatus = poseStatus
        self.retentionClass = retentionClass
    }
}

public struct ListVideosOptions: Equatable, Sendable {
    public var sessionId: String?
    public var climbId: String?
    public var retentionClass: RetentionClass?

    public init(sessionId: String? = nil, climbId: String? = nil, retentionClass: RetentionClass? = nil) {
        self.sessionId = sessionId
        self.climbId = climbId
        self.retentionClass = retentionClass
    }
}

public struct ListPhotosFilter: Equatable, Sendable {
    public var climbId: String?
    public var sessionId: String?

    public init(climbId: String? = nil, sessionId: String? = nil) {
        self.climbId = climbId
        self.sessionId = sessionId
    }
}

public struct UpdateVideoPatch: Equatable, Sendable {
    public var poseStatus: PatchValue<PoseStatus>
    public var retentionClass: PatchValue<RetentionClass>

    public init(poseStatus: PatchValue<PoseStatus> = .unchanged, retentionClass: PatchValue<RetentionClass> = .unchanged) {
        self.poseStatus = poseStatus
        self.retentionClass = retentionClass
    }
}

public struct AddPoseKeypointInput: Equatable, Sendable {
    public var videoId: String
    public var tMs: Int
    public var score: Double?
    public var keypointsJson: String

    public init(videoId: String, tMs: Int, score: Double? = nil, keypointsJson: String) {
        self.videoId = videoId
        self.tMs = tMs
        self.score = score
        self.keypointsJson = keypointsJson
    }
}

public protocol MediaRepository: Sendable {
    func createPhoto(_ input: CreatePhotoInput) throws -> Photo
    func getPhoto(id: String) throws -> Photo?
    func listPhotos(filter: ListPhotosFilter) throws -> [Photo]
    func updatePhotoThumb(id: String, thumbUri: String?) throws
    func deletePhoto(id: String) throws
    func createVideo(_ input: CreateVideoInput) throws -> Video
    func getVideo(id: String) throws -> Video?
    func listVideos(options: ListVideosOptions) throws -> [Video]
    func updateVideo(id: String, patch: UpdateVideoPatch) throws
    func deleteVideo(id: String) throws
    func addPoseKeypoint(_ input: AddPoseKeypointInput) throws -> PoseKeypoint
    func listPoseKeypoints(videoId: String) throws -> [PoseKeypoint]
}

public extension MediaRepository {
    func listPhotos() throws -> [Photo] {
        try listPhotos(filter: ListPhotosFilter())
    }

    func listVideos() throws -> [Video] {
        try listVideos(options: ListVideosOptions())
    }
}

public struct GRDBMediaRepository: MediaRepository {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - Photos

    public func createPhoto(_ input: CreatePhotoInput) throws -> Photo {
        let photo = Photo(
            id: generateID(),
            climbId: input.climbId,
            sessionId: input.sessionId,
            uri: input.uri,
            thumbUri: input.thumbUri,
            width: input.width,
            height: input.height,
            source: input.source,
            capturedAt: input.capturedAt ?? nowISO8601(),
            createdAt: nowISO8601()
        )
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO photos (id, climb_id, session_id, uri, thumb_uri, width, height, source,
                    captured_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    photo.id, photo.climbId, photo.sessionId, photo.uri, photo.thumbUri, photo.width, photo.height,
                    photo.source.rawValue, photo.capturedAt, photo.createdAt,
                ]
            )
        }
        return photo
    }

    public func getPhoto(id: String) throws -> Photo? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM photos WHERE id = ?", arguments: [id]).map { try rowToPhoto($0) }
        }
    }

    public func listPhotos(filter: ListPhotosFilter) throws -> [Photo] {
        try writer.read { db in
            var clauses: [String] = []
            var arguments: [DatabaseValueConvertible] = []
            if let climbId = filter.climbId {
                clauses.append("climb_id = ?")
                arguments.append(climbId)
            }
            if let sessionId = filter.sessionId {
                clauses.append("session_id = ?")
                arguments.append(sessionId)
            }
            let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
            return try Row
                .fetchAll(db, sql: "SELECT * FROM photos \(whereClause) ORDER BY captured_at DESC", arguments: StatementArguments(arguments))
                .map { try rowToPhoto($0) }
        }
    }

    public func updatePhotoThumb(id: String, thumbUri: String?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE photos SET thumb_uri = ? WHERE id = ?", arguments: [thumbUri, id])
        }
    }

    public func deletePhoto(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM photos WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Videos

    public func createVideo(_ input: CreateVideoInput) throws -> Video {
        let video = Video(
            id: generateID(),
            sessionId: input.sessionId,
            climbId: input.climbId,
            uri: input.uri,
            width: input.width,
            height: input.height,
            durationMs: input.durationMs,
            fps: input.fps,
            poseStatus: input.poseStatus,
            retentionClass: input.retentionClass,
            createdAt: nowISO8601()
        )
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO videos (id, session_id, climb_id, uri, width, height, duration_ms, fps,
                    pose_status, retention_class, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    video.id, video.sessionId, video.climbId, video.uri, video.width, video.height,
                    video.durationMs, video.fps, video.poseStatus.rawValue, video.retentionClass.rawValue,
                    video.createdAt,
                ]
            )
        }
        return video
    }

    public func getVideo(id: String) throws -> Video? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM videos WHERE id = ?", arguments: [id]).map { try rowToVideo($0) }
        }
    }

    public func listVideos(options: ListVideosOptions) throws -> [Video] {
        try writer.read { db in
            var clauses: [String] = []
            var arguments: [DatabaseValueConvertible] = []
            if let sessionId = options.sessionId {
                clauses.append("session_id = ?")
                arguments.append(sessionId)
            }
            if let climbId = options.climbId {
                clauses.append("climb_id = ?")
                arguments.append(climbId)
            }
            if let retentionClass = options.retentionClass {
                clauses.append("retention_class = ?")
                arguments.append(retentionClass.rawValue)
            }
            let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
            return try Row
                .fetchAll(db, sql: "SELECT * FROM videos \(whereClause) ORDER BY created_at DESC", arguments: StatementArguments(arguments))
                .map { try rowToVideo($0) }
        }
    }

    public func updateVideo(id: String, patch: UpdateVideoPatch) throws {
        try writer.write { db in
            if case .set(let poseStatus) = patch.poseStatus {
                try db.execute(
                    sql: "UPDATE videos SET pose_status = ? WHERE id = ?",
                    arguments: [poseStatus.rawValue, id]
                )
            }
            if case .set(let retentionClass) = patch.retentionClass {
                try db.execute(
                    sql: "UPDATE videos SET retention_class = ? WHERE id = ?",
                    arguments: [retentionClass.rawValue, id]
                )
            }
        }
    }

    public func deleteVideo(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM videos WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Pose keypoints

    public func addPoseKeypoint(_ input: AddPoseKeypointInput) throws -> PoseKeypoint {
        let keypoint = PoseKeypoint(
            id: generateID(),
            videoId: input.videoId,
            tMs: input.tMs,
            score: input.score,
            keypointsJson: input.keypointsJson
        )
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO pose_keypoints (id, video_id, t_ms, score, keypoints_json) VALUES (?, ?, ?, ?, ?)",
                arguments: [keypoint.id, keypoint.videoId, keypoint.tMs, keypoint.score, keypoint.keypointsJson]
            )
        }
        return keypoint
    }

    public func listPoseKeypoints(videoId: String) throws -> [PoseKeypoint] {
        try writer.read { db in
            try Row
                .fetchAll(db, sql: "SELECT * FROM pose_keypoints WHERE video_id = ? ORDER BY t_ms", arguments: [videoId])
                .map(rowToPoseKeypoint)
        }
    }
}
