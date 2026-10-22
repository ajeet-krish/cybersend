import CyberSendDomain
import Foundation
import GRDB

// Pose analysis storage (Pose v1, migration 006). One row per analysed clip plus its events.
// The packed pose track lives in the same row as a blob; the export payload omits that column,
// so a restored analysis keeps its metadata and events and reports `needsRecompute`.

public struct AnalysisEventInput: Equatable, Sendable {
    public var type: AnalysisEventType
    public var startMs: Int
    public var endMs: Int?
    public var joint: PoseJoint?
    public var xNorm: Double?
    public var yNorm: Double?
    public var value: Double?
    public var confidence: Double

    public init(
        type: AnalysisEventType,
        startMs: Int,
        endMs: Int? = nil,
        joint: PoseJoint? = nil,
        xNorm: Double? = nil,
        yNorm: Double? = nil,
        value: Double? = nil,
        confidence: Double
    ) {
        self.type = type
        self.startMs = startMs
        self.endMs = endMs
        self.joint = joint
        self.xNorm = xNorm
        self.yNorm = yNorm
        self.value = value
        self.confidence = confidence
    }
}

public struct SaveAnalysisInput: Equatable, Sendable {
    public var videoId: String
    public var algorithmVersion: Int
    public var visionRevision: Int
    public var samplingHz: Double
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var sourceFPS: Double?
    public var cameraClass: CameraStabilityClass
    public var coverage: Double
    public var qualityFlags: String
    public var track: PoseTrack
    public var events: [AnalysisEventInput]

    public init(
        videoId: String,
        algorithmVersion: Int,
        visionRevision: Int,
        samplingHz: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFPS: Double? = nil,
        cameraClass: CameraStabilityClass,
        coverage: Double,
        qualityFlags: String = "",
        track: PoseTrack,
        events: [AnalysisEventInput] = []
    ) {
        self.videoId = videoId
        self.algorithmVersion = algorithmVersion
        self.visionRevision = visionRevision
        self.samplingHz = samplingHz
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sourceFPS = sourceFPS
        self.cameraClass = cameraClass
        self.coverage = coverage
        self.qualityFlags = qualityFlags
        self.track = track
        self.events = events
    }
}

public protocol VideoAnalysisRepository: Sendable {
    /// Replaces any existing analysis for the video and returns the stored record.
    @discardableResult
    func saveAnalysis(_ input: SaveAnalysisInput) throws -> VideoAnalysis
    func analysis(videoId: String) throws -> VideoAnalysis?
    func events(analysisId: String) throws -> [AnalysisEvent]
    func deleteAnalysis(videoId: String) throws
    func listAnalyses() throws -> [VideoAnalysis]
}

public struct GRDBVideoAnalysisRepository: VideoAnalysisRepository {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func saveAnalysis(_ input: SaveAnalysisInput) throws -> VideoAnalysis {
        let id = generateID()
        let createdAt = nowISO8601()
        let blob = PoseTrackCodec.encode(input.track)

        let analysis = VideoAnalysis(
            id: id,
            videoId: input.videoId,
            algorithmVersion: input.algorithmVersion,
            visionRevision: input.visionRevision,
            samplingHz: input.samplingHz,
            sourceWidth: input.sourceWidth,
            sourceHeight: input.sourceHeight,
            sourceFPS: input.sourceFPS,
            cameraClass: input.cameraClass,
            coverage: input.coverage,
            trackFormat: PoseTrackCodec.formatIdentifier,
            trackBlob: blob,
            qualityFlags: input.qualityFlags,
            createdAt: createdAt
        )

        let events = input.events.map { event in
            AnalysisEvent(
                id: generateID(),
                analysisId: id,
                type: event.type,
                startMs: event.startMs,
                endMs: event.endMs,
                joint: event.joint,
                xNorm: event.xNorm,
                yNorm: event.yNorm,
                value: event.value,
                confidence: event.confidence
            )
        }

        try writer.write { db in
            // One analysis per video: re-analysis replaces the old record and its events rather
            // than accumulating incomparable versions.
            try db.execute(
                sql: "DELETE FROM video_analyses WHERE video_id = ?",
                arguments: [input.videoId]
            )
            try db.execute(
                sql: """
                    INSERT INTO video_analyses (
                        id, video_id, algorithm_version, vision_revision, sampling_hz,
                        source_width, source_height, source_fps, camera_class, coverage,
                        track_format, track_blob, quality_flags, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    analysis.id,
                    analysis.videoId,
                    analysis.algorithmVersion,
                    analysis.visionRevision,
                    analysis.samplingHz,
                    analysis.sourceWidth,
                    analysis.sourceHeight,
                    analysis.sourceFPS,
                    analysis.cameraClass.rawValue,
                    analysis.coverage,
                    analysis.trackFormat,
                    analysis.trackBlob,
                    analysis.qualityFlags,
                    analysis.createdAt,
                ]
            )
            for event in events {
                try db.execute(
                    sql: """
                        INSERT INTO analysis_events (
                            id, analysis_id, type, start_ms, end_ms, joint,
                            x_norm, y_norm, value, confidence
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        event.id,
                        event.analysisId,
                        event.type.rawValue,
                        event.startMs,
                        event.endMs,
                        event.joint?.rawValue,
                        event.xNorm,
                        event.yNorm,
                        event.value,
                        event.confidence,
                    ]
                )
            }
        }

        return analysis
    }

    public func analysis(videoId: String) throws -> VideoAnalysis? {
        try writer.read { db in
            try Row
                .fetchOne(
                    db,
                    sql: "SELECT * FROM video_analyses WHERE video_id = ?",
                    arguments: [videoId]
                )
                .map(rowToVideoAnalysis)
        }
    }

    public func events(analysisId: String) throws -> [AnalysisEvent] {
        try writer.read { db in
            try Row
                .fetchAll(
                    db,
                    sql: "SELECT * FROM analysis_events WHERE analysis_id = ? ORDER BY start_ms, type",
                    arguments: [analysisId]
                )
                .map(rowToAnalysisEvent)
        }
    }

    public func deleteAnalysis(videoId: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM video_analyses WHERE video_id = ?",
                arguments: [videoId]
            )
        }
    }

    public func listAnalyses() throws -> [VideoAnalysis] {
        try writer.read { db in
            try Row
                .fetchAll(db, sql: "SELECT * FROM video_analyses ORDER BY created_at DESC")
                .map(rowToVideoAnalysis)
        }
    }
}

private func rowToVideoAnalysis(_ row: Row) throws -> VideoAnalysis {
    let cameraRaw: String = row["camera_class"]
    guard let cameraClass = CameraStabilityClass(rawValue: cameraRaw) else {
        throw DataError.unknownCameraClass(cameraRaw)
    }
    return VideoAnalysis(
        id: row["id"],
        videoId: row["video_id"],
        algorithmVersion: row["algorithm_version"],
        visionRevision: row["vision_revision"],
        samplingHz: row["sampling_hz"],
        sourceWidth: row["source_width"],
        sourceHeight: row["source_height"],
        sourceFPS: row["source_fps"],
        cameraClass: cameraClass,
        coverage: row["coverage"],
        trackFormat: row["track_format"],
        trackBlob: row["track_blob"],
        qualityFlags: row["quality_flags"],
        createdAt: row["created_at"]
    )
}

private func rowToAnalysisEvent(_ row: Row) throws -> AnalysisEvent {
    let typeRaw: String = row["type"]
    guard let type = AnalysisEventType(rawValue: typeRaw) else {
        throw DataError.unknownAnalysisEventType(typeRaw)
    }
    let jointRaw: String? = row["joint"]
    let joint = jointRaw.flatMap(PoseJoint.init(rawValue:))
    return AnalysisEvent(
        id: row["id"],
        analysisId: row["analysis_id"],
        type: type,
        startMs: row["start_ms"],
        endMs: row["end_ms"],
        joint: joint,
        xNorm: row["x_norm"],
        yNorm: row["y_norm"],
        value: row["value"],
        confidence: row["confidence"]
    )
}
