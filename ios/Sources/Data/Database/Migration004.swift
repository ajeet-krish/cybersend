import Foundation
import GRDB

// Migration 004 (UI overhaul: Problems catalog): climbs.notes, the free text problem
// details field (beta, style, what to remember). Nullable, so every existing climb stays
// valid and the column reads as "no details written yet" rather than an empty string.
//
// This is a plain ALTER TABLE ADD COLUMN, not a table rebuild: the column is appended, has
// no CHECK constraint, and Migration 003 already carried the only rebuild this schema
// needed. The export payload moves to version 4 in the same change so a backup written by
// this build round trips its details.

public let climbNotesMigration = Migration(version: 4, name: "climb_notes") { db in
    try db.execute(sql: "ALTER TABLE climbs ADD COLUMN notes TEXT")
}
