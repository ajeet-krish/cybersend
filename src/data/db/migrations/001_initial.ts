// Migration 001: the full version 1 baseline schema, transcribed verbatim from docs/schema.sql
// (the authoritative DDL; keep the two in sync). Each statement runs separately because the
// op-sqlite driver executes one statement per call. PRAGMA foreign_keys is applied at connection
// open (src/data/db/pragmas.ts) because PRAGMA statements are no-ops inside a transaction.
//
// PENDING RECONCILIATION (docs/reviews.md, open item): requirements US-9 specifies normalized
// grade storage via grade_scheme and grade_level tables, but this migration follows
// docs/schema.sql's denormalized grade_system and grade_raw text columns. Requirements wins
// (the user decision), so the Swift port must implement normalized grade tables. The same open
// item covers holds.role vs holds.label and the fell_on_hold_id naming on attempts. This
// migration and the TS repositories stay consistent with schema.sql for now; the schema rewrite
// is a separate documented step owned by the migration, not a drift to fix in place.

import type { SqlExecutor } from '../executor';
import type { Migration } from './index';

const STATEMENTS: readonly string[] = [
  `CREATE TABLE schema_migrations (
    version     INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    applied_at  TEXT NOT NULL
  )`,
  `CREATE TABLE gyms (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    timezone    TEXT,
    is_active   INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  )`,
  `CREATE TABLE walls (
    id          TEXT PRIMARY KEY,
    gym_id      TEXT NOT NULL REFERENCES gyms(id) ON DELETE CASCADE,
    name        TEXT,
    angle_deg   REAL,
    angle_label TEXT,
    is_active   INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  )`,
  'CREATE INDEX idx_walls_gym ON walls(gym_id)',
  `CREATE TABLE boards (
    id          TEXT PRIMARY KEY,
    provider    TEXT NOT NULL,
    name        TEXT NOT NULL,
    angle_deg   REAL,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  )`,
  `CREATE TABLE board_problems (
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
  )`,
  `CREATE TABLE climbs (
    id                TEXT PRIMARY KEY,
    gym_id            TEXT NOT NULL REFERENCES gyms(id) ON DELETE RESTRICT,
    wall_id           TEXT REFERENCES walls(id) ON DELETE SET NULL,
    board_id          TEXT REFERENCES boards(id) ON DELETE SET NULL,
    board_problem_id  TEXT REFERENCES board_problems(id) ON DELETE SET NULL,
    name              TEXT,
    grade_system      TEXT NOT NULL DEFAULT 'v_scale',
    grade_raw         TEXT,
    grade_norm        REAL,
    color_circuit     TEXT,
    angle_deg         REAL,
    is_active         INTEGER NOT NULL DEFAULT 1,
    is_archived       INTEGER NOT NULL DEFAULT 0,
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL
  )`,
  'CREATE INDEX idx_climbs_gym ON climbs(gym_id)',
  'CREATE INDEX idx_climbs_gym_status ON climbs(gym_id, is_active, is_archived)',
  `CREATE TABLE holds (
    id           TEXT PRIMARY KEY,
    climb_id     TEXT NOT NULL REFERENCES climbs(id) ON DELETE CASCADE,
    x_norm       REAL NOT NULL CHECK (x_norm >= 0 AND x_norm <= 1),
    y_norm       REAL NOT NULL CHECK (y_norm >= 0 AND y_norm <= 1),
    radius_norm  REAL NOT NULL DEFAULT 0.02 CHECK (radius_norm > 0),
    label        TEXT,
    color        TEXT,
    source       TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'detection', 'board')),
    ordinal      INTEGER,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
  )`,
  'CREATE INDEX idx_holds_climb ON holds(climb_id)',
  `CREATE TABLE sessions (
    id          TEXT PRIMARY KEY,
    gym_id      TEXT NOT NULL REFERENCES gyms(id) ON DELETE RESTRICT,
    started_at  TEXT NOT NULL,
    ended_at    TEXT,
    rpe         INTEGER CHECK (rpe IS NULL OR (rpe >= 1 AND rpe <= 10)),
    notes       TEXT,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  )`,
  'CREATE INDEX idx_sessions_gym_started ON sessions(gym_id, started_at)',
  `CREATE TABLE photos (
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
  )`,
  'CREATE INDEX idx_photos_climb ON photos(climb_id)',
  'CREATE INDEX idx_photos_session ON photos(session_id)',
  `CREATE TABLE videos (
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
  )`,
  'CREATE INDEX idx_videos_session ON videos(session_id)',
  'CREATE INDEX idx_videos_retention ON videos(retention_class, created_at)',
  `CREATE TABLE pose_keypoints (
    id              TEXT PRIMARY KEY,
    video_id        TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    t_ms            INTEGER NOT NULL,
    score           REAL,
    keypoints_json  TEXT NOT NULL
  )`,
  'CREATE INDEX idx_pose_video_t ON pose_keypoints(video_id, t_ms)',
  `CREATE TABLE attempts (
    id               TEXT PRIMARY KEY,
    session_id       TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    climb_id         TEXT NOT NULL REFERENCES climbs(id) ON DELETE RESTRICT,
    attempt_no       INTEGER NOT NULL,
    outcome          TEXT NOT NULL CHECK (outcome IN ('flash', 'send', 'project', 'fail')),
    fell_on_hold_id  TEXT REFERENCES holds(id) ON DELETE SET NULL,
    video_id         TEXT REFERENCES videos(id) ON DELETE SET NULL,
    notes            TEXT,
    created_at       TEXT NOT NULL
  )`,
  'CREATE INDEX idx_attempts_climb ON attempts(climb_id)',
  'CREATE INDEX idx_attempts_session ON attempts(session_id)',
  'CREATE INDEX idx_attempts_session_climb ON attempts(session_id, climb_id)',
  `CREATE TABLE grade_norm_params (
    id            TEXT PRIMARY KEY,
    scope         TEXT NOT NULL CHECK (scope IN ('global', 'gym')),
    gym_id        TEXT REFERENCES gyms(id) ON DELETE CASCADE,
    algo_version  TEXT NOT NULL,
    sample_count  INTEGER NOT NULL,
    params_json   TEXT NOT NULL,
    computed_at   TEXT NOT NULL
  )`,
  'CREATE INDEX idx_gradenorm_scope ON grade_norm_params(scope, gym_id)',
  `CREATE TABLE settings (
    key         TEXT PRIMARY KEY,
    value_json  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  )`,
];

export const initial_migration: Migration = {
  version: 1,
  name: 'initial',
  async up(tx: SqlExecutor): Promise<void> {
    for (const statement of STATEMENTS) {
      await tx.execute(statement);
    }
  },
};
