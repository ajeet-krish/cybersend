/*
 * CyberSend canonical schema, version 1 (reconciled 2026-10-19, Phase 0 M0).
 * Source of truth for the Swift port's Migration 001 (ios/Sources/Data) and the frozen
 * TypeScript port spec's 001_initial.ts. Requirements (docs/requirements.md section 2) wins over
 * the earlier denormalized draft; the full old to new mapping is recorded in docs/decisions.md
 * ("2026-10-19, Phase 0 (M0): schema reconciliation").
 * Conventions:
 *   - ids are UUIDv4 text
 *   - timestamps are ISO 8601 UTC text (e.g. 2026-10-19T14:03:11Z)
 *   - booleans are INTEGER 0 or 1
 *   - media uris are relative to the app document root for portability
 *   - canvas and vision coordinates are normalized to 0..1 over the source image
 *   - grade is stored as (grade_system_id, grade_level_id) references, never free text (US-9)
 */

PRAGMA foreign_keys = ON;

CREATE TABLE schema_migrations (
    version     INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    applied_at  TEXT NOT NULL
);

/*
 * Normalized grade storage (US-9): grade_systems and grade_levels replace the old
 * denormalized climbs.grade_system / climbs.grade_raw text columns. Built-in schemes
 * (V scale, Fontainebleau) are seeded by Migration 001; custom schemes are rows with
 * is_builtin = 0. rank_order is the display and translation order (lowest to highest);
 * color_hex is an optional per-level color for circuit styling.
 */
CREATE TABLE grade_systems (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    is_builtin  INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

CREATE TABLE grade_levels (
    id          TEXT PRIMARY KEY,
    system_id   TEXT NOT NULL REFERENCES grade_systems(id) ON DELETE CASCADE,
    label       TEXT NOT NULL,
    rank_order  INTEGER NOT NULL,
    color_hex   TEXT,
    UNIQUE (system_id, label),
    UNIQUE (system_id, rank_order)
);
CREATE INDEX idx_grade_levels_system ON grade_levels(system_id);

CREATE TABLE gyms (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    timezone    TEXT,
    is_archived INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

CREATE TABLE walls (
    id          TEXT PRIMARY KEY,
    gym_id      TEXT NOT NULL REFERENCES gyms(id) ON DELETE CASCADE,
    name        TEXT,
    angle_deg   REAL,
    angle_label TEXT,
    is_active   INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE INDEX idx_walls_gym ON walls(gym_id);

/*
 * Board tables are dormant. Board integration is cut from the roadmap as of
 * 2026-10-19 (see docs/decisions.md). The boards and board_problems tables and
 * the board columns on climbs are retained so the feature can return without a
 * migration overhaul. Nothing in the current phase map writes to them.
 */
CREATE TABLE boards (
    id          TEXT PRIMARY KEY,
    provider    TEXT NOT NULL,
    name        TEXT NOT NULL,
    angle_deg   REAL,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

CREATE TABLE board_problems (
    id           TEXT PRIMARY KEY,
    board_id     TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
    provider     TEXT NOT NULL,
    external_id  TEXT,
    name         TEXT,
    grade_raw    TEXT,
    angle_deg    REAL,
    holds_json   TEXT NOT NULL,
    is_active    INTEGER NOT NULL DEFAULT 1,
    imported_at  TEXT NOT NULL,
    UNIQUE (board_id, external_id)
);

/*
 * board_id and board_problem_id are dormant (board integration deferred, see docs/decisions.md).
 * grade_system_id defaults to the seeded V scale; grade_level_id is null until a grade is set.
 */
CREATE TABLE climbs (
    id                TEXT PRIMARY KEY,
    gym_id            TEXT NOT NULL REFERENCES gyms(id) ON DELETE RESTRICT,
    wall_id           TEXT REFERENCES walls(id) ON DELETE SET NULL,
    board_id          TEXT REFERENCES boards(id) ON DELETE SET NULL,
    board_problem_id  TEXT REFERENCES board_problems(id) ON DELETE SET NULL,
    name              TEXT,
    grade_system_id   TEXT NOT NULL DEFAULT 'v_scale' REFERENCES grade_systems(id) ON DELETE RESTRICT,
    grade_level_id    TEXT REFERENCES grade_levels(id) ON DELETE SET NULL,
    grade_norm        REAL,
    color_circuit     TEXT,
    angle_deg         REAL,
    is_active         INTEGER NOT NULL DEFAULT 1,
    is_archived       INTEGER NOT NULL DEFAULT 0,
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL
);
CREATE INDEX idx_climbs_gym ON climbs(gym_id);
CREATE INDEX idx_climbs_gym_status ON climbs(gym_id, is_active, is_archived);

/*
 * Holds are tagged on a climb photo (Phase 2). role is the tagging enum (US-19:
 * start, intermediate, top; null until assigned). color_family is the optional
 * color grouping for circuit styling (US-33 suggestion target). Coordinates are
 * normalized 0..1 over the source image.
 */
CREATE TABLE holds (
    id            TEXT PRIMARY KEY,
    climb_id      TEXT NOT NULL REFERENCES climbs(id) ON DELETE CASCADE,
    x_norm        REAL NOT NULL CHECK (x_norm >= 0 AND x_norm <= 1),
    y_norm        REAL NOT NULL CHECK (y_norm >= 0 AND y_norm <= 1),
    radius_norm   REAL NOT NULL DEFAULT 0.02 CHECK (radius_norm > 0),
    role          TEXT CHECK (role IS NULL OR role IN ('start', 'intermediate', 'top')),
    color_family  TEXT,
    source        TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'detection', 'board')),
    ordinal       INTEGER,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);
CREATE INDEX idx_holds_climb ON holds(climb_id);

CREATE TABLE sessions (
    id          TEXT PRIMARY KEY,
    gym_id      TEXT NOT NULL REFERENCES gyms(id) ON DELETE RESTRICT,
    started_at  TEXT NOT NULL,
    ended_at    TEXT,
    rpe         INTEGER CHECK (rpe IS NULL OR (rpe >= 1 AND rpe <= 10)),
    notes       TEXT,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE INDEX idx_sessions_gym_started ON sessions(gym_id, started_at);

CREATE TABLE photos (
    id            TEXT PRIMARY KEY,
    climb_id      TEXT REFERENCES climbs(id) ON DELETE SET NULL,
    session_id    TEXT REFERENCES sessions(id) ON DELETE SET NULL,
    uri           TEXT NOT NULL,
    thumb_uri     TEXT,
    width         INTEGER NOT NULL,
    height        INTEGER NOT NULL,
    source        TEXT NOT NULL DEFAULT 'camera' CHECK (source IN ('camera', 'library')),
    captured_at   TEXT NOT NULL,
    created_at    TEXT NOT NULL
);
CREATE INDEX idx_photos_climb ON photos(climb_id);
CREATE INDEX idx_photos_session ON photos(session_id);

CREATE TABLE videos (
    id              TEXT PRIMARY KEY,
    session_id      TEXT REFERENCES sessions(id) ON DELETE SET NULL,
    climb_id        TEXT REFERENCES climbs(id) ON DELETE SET NULL,
    uri             TEXT NOT NULL,
    width           INTEGER,
    height          INTEGER,
    duration_ms     INTEGER,
    fps             REAL,
    pose_status     TEXT NOT NULL DEFAULT 'none'
                    CHECK (pose_status IN ('none', 'pending', 'running', 'done', 'failed')),
    retention_class TEXT NOT NULL DEFAULT 'ephemeral'
                    CHECK (retention_class IN ('ephemeral', 'keep')),
    created_at      TEXT NOT NULL
);
CREATE INDEX idx_videos_session ON videos(session_id);
CREATE INDEX idx_videos_retention ON videos(retention_class, created_at);

CREATE TABLE pose_keypoints (
    id              TEXT PRIMARY KEY,
    video_id        TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    t_ms            INTEGER NOT NULL,
    score           REAL,
    keypoints_json  TEXT NOT NULL
);
CREATE INDEX idx_pose_video_t ON pose_keypoints(video_id, t_ms);

/*
 * Attempts record the moment the attempt happened in attempted_at (requirements section 2;
 * the old schema.sql used created_at for this column). fall_on_hold_id is the requirements
 * name for the old fell_on_hold_id column. attempt_no is a per (session_id, climb_id)
 * integer maintained by the repository.
 */
CREATE TABLE attempts (
    id               TEXT PRIMARY KEY,
    session_id       TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    climb_id         TEXT NOT NULL REFERENCES climbs(id) ON DELETE RESTRICT,
    attempt_no       INTEGER NOT NULL,
    outcome          TEXT NOT NULL CHECK (outcome IN ('flash', 'send', 'project', 'fail')),
    fall_on_hold_id  TEXT REFERENCES holds(id) ON DELETE SET NULL,
    video_id         TEXT REFERENCES videos(id) ON DELETE SET NULL,
    notes            TEXT,
    attempted_at     TEXT NOT NULL
);
CREATE INDEX idx_attempts_climb ON attempts(climb_id);
CREATE INDEX idx_attempts_session ON attempts(session_id);
CREATE INDEX idx_attempts_session_climb ON attempts(session_id, climb_id);

CREATE TABLE grade_norm_params (
    id            TEXT PRIMARY KEY,
    scope         TEXT NOT NULL CHECK (scope IN ('global', 'gym')),
    gym_id        TEXT REFERENCES gyms(id) ON DELETE CASCADE,
    algo_version  TEXT NOT NULL,
    sample_count  INTEGER NOT NULL,
    params_json   TEXT NOT NULL,
    computed_at   TEXT NOT NULL
);
CREATE INDEX idx_gradenorm_scope ON grade_norm_params(scope, gym_id);

CREATE TABLE settings (
    key         TEXT PRIMARY KEY,
    value_json  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

/*
 * Built-in grade scheme seed data (Migration 001 runs these inserts after the DDL).
 * Level ids are stable identifiers (lowercased labels; '+' becomes _plus), rank_order
 * ascends lowest to highest, color_hex stays null for built-ins.
 */
INSERT INTO grade_systems (id, name, is_builtin, created_at, updated_at) VALUES
    ('v_scale', 'V Scale', 1, '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z'),
    ('font', 'Fontainebleau', 1, '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z');

INSERT INTO grade_levels (id, system_id, label, rank_order, color_hex) VALUES
    ('v0', 'v_scale', 'V0', 0, NULL),
    ('v1', 'v_scale', 'V1', 1, NULL),
    ('v2', 'v_scale', 'V2', 2, NULL),
    ('v3', 'v_scale', 'V3', 3, NULL),
    ('v4', 'v_scale', 'V4', 4, NULL),
    ('v5', 'v_scale', 'V5', 5, NULL),
    ('v6', 'v_scale', 'V6', 6, NULL),
    ('v7', 'v_scale', 'V7', 7, NULL),
    ('v8', 'v_scale', 'V8', 8, NULL),
    ('v9', 'v_scale', 'V9', 9, NULL),
    ('v10', 'v_scale', 'V10', 10, NULL),
    ('v11', 'v_scale', 'V11', 11, NULL),
    ('v12', 'v_scale', 'V12', 12, NULL),
    ('v13', 'v_scale', 'V13', 13, NULL),
    ('v14', 'v_scale', 'V14', 14, NULL),
    ('v15', 'v_scale', 'V15', 15, NULL),
    ('v16', 'v_scale', 'V16', 16, NULL),
    ('v17', 'v_scale', 'V17', 17, NULL),
    ('f1', 'font', '1', 0, NULL),
    ('f2', 'font', '2', 1, NULL),
    ('f3', 'font', '3', 2, NULL),
    ('f4', 'font', '4', 3, NULL),
    ('f4_plus', 'font', '4+', 4, NULL),
    ('f5', 'font', '5', 5, NULL),
    ('f5_plus', 'font', '5+', 6, NULL),
    ('f6a', 'font', '6a', 7, NULL),
    ('f6a_plus', 'font', '6a+', 8, NULL),
    ('f6b', 'font', '6b', 9, NULL),
    ('f6b_plus', 'font', '6b+', 10, NULL),
    ('f6c', 'font', '6c', 11, NULL),
    ('f6c_plus', 'font', '6c+', 12, NULL),
    ('f7a', 'font', '7a', 13, NULL),
    ('f7a_plus', 'font', '7a+', 14, NULL),
    ('f7b', 'font', '7b', 15, NULL),
    ('f7b_plus', 'font', '7b+', 16, NULL),
    ('f7c', 'font', '7c', 17, NULL),
    ('f7c_plus', 'font', '7c+', 18, NULL),
    ('f8a', 'font', '8a', 19, NULL),
    ('f8a_plus', 'font', '8a+', 20, NULL),
    ('f8b', 'font', '8b', 21, NULL),
    ('f8b_plus', 'font', '8b+', 22, NULL),
    ('f8c', 'font', '8c', 23, NULL),
    ('f8c_plus', 'font', '8c+', 24, NULL),
    ('f9a', 'font', '9a', 25, NULL);
