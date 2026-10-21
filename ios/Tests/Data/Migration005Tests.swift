import Foundation
import GRDB
import Testing
@testable import CyberSendData

// Migration 005 tests (UI overhaul): climbs.categories is appended as a nullable text column,
// so existing climbs keep their data and read as "no categories tagged" until they are
// edited. The parser ignores unknown tokens, which keeps a row written by a newer build
// readable here.

@Suite("Migration 005 climb categories")
struct Migration005Tests {
    private func version4Database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(
            on: db,
            migrations: [initialMigration, climbHoldsMigration, attemptRpeMigration, climbNotesMigration]
        )
        return db
    }

    @Test("empty upgrade appends a nullable climbs.categories column and lands version 5")
    func emptyUpgrade() throws {
        let db = try version4Database()

        let result = try runPendingMigrations(on: db)
        #expect(result.applied == [5])

        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(climbs)")
        }
        let categoriesColumn = try #require(columns.first { row in (row["name"] as String) == "categories" })
        let notNull: Int = categoriesColumn["notnull"]
        #expect(notNull == 0, "categories stays nullable so existing climbs remain valid")

        let version = try db.read { try readSchemaVersion(on: $0) }
        #expect(version == 5)
        let auditName = try db.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM schema_migrations WHERE version = 5")
        }
        #expect(auditName == "climb_categories")
    }

    @Test("climbs written before the upgrade keep their data and start with no categories")
    func existingClimbsKeepData() throws {
        let db = try version4Database()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO gyms (id, name, is_archived, created_at, updated_at)
                VALUES ('gym-1', 'Gym', 0, 't0', 't0')
            """)
            try db.execute(sql: """
                INSERT INTO climbs (id, gym_id, name, grade_system_id, grade_level_id, notes,
                    is_active, is_archived, created_at, updated_at)
                VALUES ('climb-1', 'gym-1', 'Blue', 'v_scale', 'v4', 'beta', 1, 0, 't0', 't0')
            """)
        }

        _ = try runPendingMigrations(on: db)

        let row = try #require(try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM climbs WHERE id = 'climb-1'")
        })
        #expect(row["name"] as String == "Blue")
        #expect(row["notes"] as String == "beta")
        #expect(row["categories"] as String? == nil)
    }
}
