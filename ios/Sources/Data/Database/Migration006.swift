import Foundation
import GRDB

// Migration 006 (Pose v1 storage, M6): the analysis record and its events.
//
// One row per analysed video, not one row per frame. The pose track itself is a single packed
// blob (PoseTrackCodec) because 30 seconds at 30 Hz is about 103 KB, and a row per frame would
// turn a 240 fps slow motion clip into thousands of rows for no benefit. The blob is nullable
// because the export payload does not carry it: a restored backup keeps the analysis metadata and
// events and marks the track for recompute rather than shipping a large opaque column through
// JSON.
//
// pose_keypoints stays in place and stops being written. Dropping it is a later migration once no
// fixture references it (docs/decisions.md, 2026-10-21 Phase 5 record).

public let poseAnalysisMigration = Migration(version: 6, name: "pose_analysis") { db in
    try db.execute(sql: """
        CREATE TABLE video_analyses (
            id                 TEXT PRIMARY KEY,
            video_id           TEXT NOT NULL UNIQUE REFERENCES videos(id) ON DELETE CASCADE,
            algorithm_version  INTEGER NOT NULL,
            vision_revision    INTEGER NOT NULL,
            sampling_hz        REAL NOT NULL,
            source_width       INTEGER NOT NULL,
            source_height      INTEGER NOT NULL,
            source_fps         REAL,
            camera_class       TEXT NOT NULL
                               CHECK (camera_class IN ('static', 'near_static', 'handheld')),
            coverage           REAL NOT NULL,
            track_format       TEXT,
            track_blob         BLOB,
            quality_flags      TEXT NOT NULL DEFAULT '',
            created_at         TEXT NOT NULL
        )
        """)

    try db.execute(sql: "CREATE INDEX idx_video_analyses_video ON video_analyses(video_id)")

    try db.execute(sql: """
        CREATE TABLE analysis_events (
            id           TEXT PRIMARY KEY,
            analysis_id  TEXT NOT NULL REFERENCES video_analyses(id) ON DELETE CASCADE,
            type         TEXT NOT NULL,
            start_ms     INTEGER NOT NULL,
            end_ms       INTEGER,
            joint        TEXT,
            x_norm       REAL,
            y_norm       REAL,
            value        REAL,
            confidence   REAL NOT NULL
        )
        """)

    try db.execute(
        sql: "CREATE INDEX idx_analysis_events_analysis ON analysis_events(analysis_id, type)"
    )
}
