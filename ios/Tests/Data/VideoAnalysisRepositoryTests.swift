import CyberSendDomain
import Foundation
import GRDB
import Testing
@testable import CyberSendData
@testable import CyberSendFeatures

// Pose analysis storage (migration 006): one row per analysed clip, packed track blob,
// replace on re-analysis, and cascade delete with the video.

@Suite("Pose analysis storage")
struct VideoAnalysisRepositoryTests {
    private func sampleTrack() -> PoseTrack {
        PoseTrack(
            samplingHz: 30,
            sourceWidth: 720,
            sourceHeight: 1280,
            sourceFPS: 60,
            visionRevision: 3,
            frames: [
                PoseFrame(tMs: 0, joints: [
                    .neck: JointSample(x: 0.5, y: 0.25, confidence: 0.9),
                    .leftWrist: JointSample(x: 0.25, y: 0.5, confidence: 0.75),
                ]),
                PoseFrame(tMs: 33, joints: [
                    .neck: JointSample(x: 0.5, y: 0.3, confidence: 0.8),
                ]),
            ]
        )
    }

    private func input(videoId: String, events: [AnalysisEventInput] = []) -> SaveAnalysisInput {
        SaveAnalysisInput(
            videoId: videoId,
            algorithmVersion: 1,
            visionRevision: 3,
            samplingHz: 30,
            sourceWidth: 720,
            sourceHeight: 1280,
            sourceFPS: 60,
            cameraClass: .stationary,
            coverage: 0.82,
            qualityFlags: "low_coverage_tail",
            track: sampleTrack(),
            events: events
        )
    }

    @Test("saves an analysis with a decodable track and its events")
    func savesAnalysis() throws {
        let test = try makeTestDatabase()
        let video = try test.repos.media.createVideo(CreateVideoInput(uri: "videos/a.mov"))

        let stored = try test.repos.videoAnalysis.saveAnalysis(input(
            videoId: video.id,
            events: [
                AnalysisEventInput(type: .attemptStart, startMs: 1200, confidence: 0.8),
                AnalysisEventInput(type: .fall, startMs: 14_200, endMs: 15_000, confidence: 0.7),
            ]
        ))

        #expect(stored.videoId == video.id)
        #expect(stored.cameraClass == .stationary)
        #expect(stored.coverage == 0.82)
        #expect(stored.needsRecompute == false)
        #expect(stored.trackFormat == PoseTrackCodec.formatIdentifier)

        let record = try test.repos.videoAnalysis.analysis(videoId: video.id)
        let fetched = try #require(record)
        #expect(fetched.id == stored.id)
        #expect(fetched.qualityFlags == "low_coverage_tail")

        let blob = try #require(fetched.trackBlob)
        let track = try PoseTrackCodec.decode(blob)
        #expect(track.frames.count == 2)
        #expect(track.frames[0].joints[.leftWrist]?.confidence == 0.75)

        let events = try test.repos.videoAnalysis.events(analysisId: stored.id)
        #expect(events.map(\.type) == [.attemptStart, .fall])
        #expect(events[1].durationMs == 800)
    }

    @Test("re-analysis replaces the record instead of accumulating versions")
    func reanalysisReplaces() throws {
        let test = try makeTestDatabase()
        let video = try test.repos.media.createVideo(CreateVideoInput(uri: "videos/b.mov"))

        let first = try test.repos.videoAnalysis.saveAnalysis(input(
            videoId: video.id,
            events: [AnalysisEventInput(type: .fall, startMs: 9000, confidence: 0.6)]
        ))
        let second = try test.repos.videoAnalysis.saveAnalysis(input(
            videoId: video.id,
            events: [
                AnalysisEventInput(type: .fall, startMs: 9100, confidence: 0.8),
                AnalysisEventInput(type: .dyno, startMs: 5000, endMs: 5400, confidence: 0.7),
            ]
        ))

        #expect(first.id != second.id)

        let analyses = try test.repos.videoAnalysis.listAnalyses()
        #expect(analyses.count == 1)

        let events = try test.repos.videoAnalysis.events(analysisId: second.id)
        #expect(events.count == 2)

        let staleEvents = try test.repos.videoAnalysis.events(analysisId: first.id)
        #expect(staleEvents.isEmpty)
    }

    @Test("deleting the video cascades to the analysis and its events")
    func cascadeDelete() throws {
        let test = try makeTestDatabase()
        let video = try test.repos.media.createVideo(CreateVideoInput(uri: "videos/c.mov"))
        let stored = try test.repos.videoAnalysis.saveAnalysis(input(
            videoId: video.id,
            events: [AnalysisEventInput(type: .attemptStart, startMs: 0, confidence: 1)]
        ))

        try test.writer.write { db in
            try db.execute(sql: "DELETE FROM videos WHERE id = ?", arguments: [video.id])
        }

        let remaining = try test.repos.videoAnalysis.analysis(videoId: video.id)
        #expect(remaining == nil)

        let remainingEvents = try test.repos.videoAnalysis.events(analysisId: stored.id)
        #expect(remainingEvents.isEmpty)
    }

    @Test("the export payload carries analysis metadata but never the track blob")
    func exportOmitsTheBlob() throws {
        let test = try makeTestDatabase()
        let video = try test.repos.media.createVideo(CreateVideoInput(uri: "videos/d.mov"))
        _ = try test.repos.videoAnalysis.saveAnalysis(input(videoId: video.id))

        let dump = try test.repos.dump.dumpAll()
        let rows = try #require(dump[.videoAnalyses])
        let row = try #require(rows.first)

        #expect(row["track_blob"] == nil, "the packed track stays out of the JSON export")
        #expect(row["camera_class"] == .text("static"))
        #expect(row["coverage"] == .real(0.82))
    }

    @Test("a backup round trip keeps analysis metadata and events and marks the track for recompute")
    func backupRoundTrip() throws {
        let source = try makeTestDatabase()
        let video = try source.repos.media.createVideo(CreateVideoInput(uri: "videos/f.mov"))
        let stored = try source.repos.videoAnalysis.saveAnalysis(input(
            videoId: video.id,
            events: [
                AnalysisEventInput(type: .attemptStart, startMs: 500, confidence: 0.9),
                AnalysisEventInput(type: .fall, startMs: 8000, endMs: 8600, confidence: 0.8),
            ]
        ))

        let json = try buildExportJSON(repos: source.repos, now: "2026-10-21T00:00:00.000Z")
        #expect(!json.contains("track_blob"))

        let target = try makeTestDatabase()
        _ = try importPayloadJSON(json, on: target.writer)

        let record = try target.repos.videoAnalysis.analysis(videoId: video.id)
        let restored = try #require(record)
        #expect(restored.id == stored.id)
        #expect(restored.cameraClass == .stationary)
        #expect(restored.coverage == 0.82)
        #expect(restored.trackFormat == PoseTrackCodec.formatIdentifier)
        #expect(restored.needsRecompute, "the track blob is not exported, so a restore needs a recompute")

        let events = try target.repos.videoAnalysis.events(analysisId: stored.id)
        #expect(events.map(\.type) == [.attemptStart, .fall])
        #expect(events[1].durationMs == 600)
    }
}

@Suite("Migration 006 pose analysis tables")
struct Migration006Tests {
    private func version5Database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(on: db, migrations: [
            initialMigration,
            climbHoldsMigration,
            attemptRpeMigration,
            climbNotesMigration,
            climbCategoriesMigration,
        ])
        return db
    }

    @Test("upgrading a version 5 database keeps existing videos and adds empty analysis tables")
    func upgradeKeepsVideos() throws {
        let db = try version5Database()
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO videos (id, uri, pose_status, retention_class, created_at)
                    VALUES ('video-1', 'videos/a.mov', 'none', 'keep', '2026-10-01T00:00:00.000Z')
                    """
            )
        }

        let result = try runPendingMigrations(on: db)
        #expect(result.applied == [6])

        let videos = try db.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM videos")
        }
        #expect(videos == ["video-1"])

        let analyses = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM video_analyses") ?? -1
        }
        #expect(analyses == 0)

        let version = try db.read { db in
            try readSchemaVersion(on: db)
        }
        #expect(version == 6)
    }

    @Test("one analysis per video is enforced by the schema")
    func oneAnalysisPerVideo() throws {
        let test = try makeTestDatabase()
        let video = try test.repos.media.createVideo(CreateVideoInput(uri: "videos/e.mov"))

        var threw = false
        do {
            try test.writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO video_analyses (
                            id, video_id, algorithm_version, vision_revision, sampling_hz,
                            source_width, source_height, camera_class, coverage, created_at
                        ) VALUES ('a1', ?, 1, 1, 30, 720, 1280, 'static', 0.5, '2026-10-01T00:00:00.000Z')
                        """,
                    arguments: [video.id]
                )
                try db.execute(
                    sql: """
                        INSERT INTO video_analyses (
                            id, video_id, algorithm_version, vision_revision, sampling_hz,
                            source_width, source_height, camera_class, coverage, created_at
                        ) VALUES ('a2', ?, 1, 1, 30, 720, 1280, 'static', 0.5, '2026-10-01T00:00:00.000Z')
                        """,
                    arguments: [video.id]
                )
            }
        } catch {
            threw = true
        }

        #expect(threw, "video_id is unique, so a second analysis must be rejected")
    }
}
