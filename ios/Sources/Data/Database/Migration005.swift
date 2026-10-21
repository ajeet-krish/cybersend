import Foundation
import GRDB

// Migration 005 (UI overhaul: climb categories): climbs.categories, a comma separated list
// of canonical category tokens (slab, overhang, dyno, and so on). Nullable and appended, so
// every existing climb stays valid and reads as "no categories tagged". Unknown tokens are
// ignored by the parser, which keeps a row written by a newer build readable here.
//
// Categories are descriptive only, so this is a plain ALTER TABLE ADD COLUMN and the export
// payload moves to version 5 in the same change.

public let climbCategoriesMigration = Migration(version: 5, name: "climb_categories") { db in
    try db.execute(sql: "ALTER TABLE climbs ADD COLUMN categories TEXT")
}
