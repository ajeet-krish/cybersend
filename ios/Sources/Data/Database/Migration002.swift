import Foundation
import GRDB

// Migration 002 (M3, US-20): the climb_holds join table for holds shareable across
// climbs with an optional beta sequence, plus photos.original_uri for retained
// originals (docs/decisions.md "2026-10-20, Phase 2 (M3): climb_holds join table via
// Migration 002, export payload version 2"). Forward only, one transaction through the
// shared runner: every existing hold is backfilled into climb_holds keyed by its
// holds.climb_id (the origin climb), with the hold's ordinal carried across as the
// sequence, so no pre-M3 climb loses its holds. holds.climb_id itself stays untouched.

private let statements: [String] = [
    """
    CREATE TABLE climb_holds (
        climb_id    TEXT NOT NULL REFERENCES climbs(id) ON DELETE CASCADE,
        hold_id     TEXT NOT NULL REFERENCES holds(id) ON DELETE CASCADE,
        sequence    INTEGER,
        created_at  TEXT NOT NULL,
        PRIMARY KEY (climb_id, hold_id)
    )
    """,
    "CREATE INDEX idx_climb_holds_hold ON climb_holds(hold_id)",
    // Backfill: one membership row per hold, owned by the hold's origin climb.
    """
    INSERT INTO climb_holds (climb_id, hold_id, sequence, created_at)
    SELECT climb_id, id, ordinal, created_at FROM holds
    """,
    "ALTER TABLE photos ADD COLUMN original_uri TEXT",
]

public let climbHoldsMigration = Migration(version: 2, name: "climb_holds") { db in
    for statement in statements {
        try db.execute(sql: statement)
    }
}
