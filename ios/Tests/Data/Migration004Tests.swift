import Foundation
import GRDB
import Testing
@testable import CyberSendData

// Migration 004 tests (Problems catalog): climbs.notes is appended as a nullable text
// column, so existing climbs keep their data and simply read as "no details written yet".

@Suite("Migration 004 climb notes")
struct Migration004Tests {
    private func version3Database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(
            on: db,
            migrations: [initialMigration, climbHoldsMigration, attemptRpeMigration]
        )
        return db
    }

    @Test("empty upgrade appends a nullable climbs.notes column and lands version 4")
    func emptyUpgrade() throws {
        let db = try version3Database()

        let result = try runPendingMigrations(on: db)
        #expect(result.applied == [4])

        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(climbs)")
        }
        let notesColumn = try #require(columns.first { row in (row["name"] as String) == "notes" })
        let notNull: Int = notesColumn["notnull"]
        #expect(notNull == 0, "notes stays nullable so existing climbs remain valid")

        let version = try db.read { try readSchemaVersion(on: $0) }
        #expect(version == 4)
        let auditName = try db.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM schema_migrations WHERE version = 4")
        }
        #expect(auditName == "climb_notes")
    }

    @Test("climbs written before the upgrade keep their data and start with nil details")
    func existingClimbsKeepData() throws {
        let db = try version3Database()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO gyms (id, name, is_archived, created_at, updated_at)
                VALUES ('gym-1', 'Gym', 0, 't0', 't0')
            """)
            try db.execute(sql: """
                INSERT INTO climbs (id, gym_id, name, grade_system_id, grade_level_id, angle_deg,
                    is_active, is_archived, created_at, updated_at)
                VALUES ('climb-1', 'gym-1', 'Blue V4', 'v_scale', 'v4', 30, 1, 0, 't0', 't0')
            """)
        }

        _ = try runPendingMigrations(on: db)

        let climb = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM climbs WHERE id = 'climb-1'")
        }
        let row = try #require(climb)
        #expect(row["name"] as String == "Blue V4")
        #expect(row["grade_level_id"] as String == "v4")
        #expect(row["angle_deg"] as Double == 30)
        #expect(row["notes"] as String? == nil)
    }
}
