import Foundation
import GRDB

// Migration 003 (M4 UI overhaul): per attempt RPE, and the removal of the project
// outcome (docs/decisions.md "2026-10-21, M4: attempt RPE and the retirement of the
// project outcome").
//
// Two schema changes land together because SQLite cannot alter a CHECK constraint in
// place. Both need one table rebuild, so paying for two rebuilds would be waste:
//  1. attempts gains rpe, nullable, the same 1 to 10 domain as sessions.rpe. Per climb
//     effort is logged at the attempt and the session total stays at close time.
//  2. outcome loses 'project'. The product decision is that fail is the only non send
//     outcome; historical project rows are rewritten to fail so no row can fail the new
//     CHECK and no attempt is lost.
//
// The copy is explicit column by column (never SELECT *) so a future reader can see
// exactly what survived. Indexes are recreated after the rename because DROP TABLE takes
// the old ones with it. Nothing references attempts, so no other table's foreign keys
// are rewritten by the rename.

private let attemptRpeStatements: [String] = [
    """
    CREATE TABLE attempts_new (
        id               TEXT PRIMARY KEY,
        session_id       TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        climb_id         TEXT NOT NULL REFERENCES climbs(id) ON DELETE RESTRICT,
        attempt_no       INTEGER NOT NULL,
        outcome          TEXT NOT NULL CHECK (outcome IN ('flash', 'send', 'fail')),
        fall_on_hold_id  TEXT REFERENCES holds(id) ON DELETE SET NULL,
        video_id         TEXT REFERENCES videos(id) ON DELETE SET NULL,
        notes            TEXT,
        attempted_at     TEXT NOT NULL,
        rpe              INTEGER CHECK (rpe IS NULL OR (rpe >= 1 AND rpe <= 10))
    )
    """,
    """
    INSERT INTO attempts_new (
        id, session_id, climb_id, attempt_no, outcome, fall_on_hold_id, video_id, notes,
        attempted_at, rpe
    )
    SELECT
        id, session_id, climb_id, attempt_no,
        CASE WHEN outcome = 'project' THEN 'fail' ELSE outcome END,
        fall_on_hold_id, video_id, notes, attempted_at, NULL
    FROM attempts
    """,
    "DROP TABLE attempts",
    "ALTER TABLE attempts_new RENAME TO attempts",
    "CREATE INDEX idx_attempts_climb ON attempts(climb_id)",
    "CREATE INDEX idx_attempts_session ON attempts(session_id)",
    "CREATE INDEX idx_attempts_session_climb ON attempts(session_id, climb_id)",
]

public let attemptRpeMigration = Migration(version: 3, name: "attempt_rpe") { db in
    for statement in attemptRpeStatements {
        try db.execute(sql: statement)
    }
}
