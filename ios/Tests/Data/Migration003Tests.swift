import Foundation
import GRDB
import Testing
@testable import CyberSendData

// Migration 003 tests (M4 UI overhaul): per attempt RPE and the retirement of the project
// outcome. Both changes ride one table rebuild because SQLite cannot alter a CHECK in
// place, so the tests pin the column, the narrowed CHECK, the historical rewrite, and the
// audit row.

@Suite("Migration 003 attempt RPE")
struct Migration003Tests {
    /// A database at version 2, the shape M3 builds shipped.
    private func version2Database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(on: db, migrations: [initialMigration, climbHoldsMigration])
        return db
    }

    private func seedOwnerChain(_ db: DatabaseQueue, attemptRows: String) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO gyms (id, name, is_archived, created_at, updated_at)
                VALUES ('gym-1', 'Gym', 0, 't0', 't0')
            """)
            try db.execute(sql: """
                INSERT INTO climbs (id, gym_id, is_active, is_archived, created_at, updated_at)
                VALUES ('climb-1', 'gym-1', 1, 0, 't0', 't0')
            """)
            try db.execute(sql: """
                INSERT INTO sessions (id, gym_id, started_at, created_at, updated_at)
                VALUES ('session-1', 'gym-1', 't1', 't1', 't1')
            """)
            try db.execute(sql: attemptRows)
        }
    }

    @Test("empty upgrade adds the nullable rpe column and lands version 3")
    func emptyUpgrade() throws {
        let db = try version2Database()

        // Scoped to versions 1 through 3 so this suite keeps testing migration 003 itself
        // rather than every later migration the build ships.
        let result = try runPendingMigrations(
            on: db,
            migrations: [initialMigration, climbHoldsMigration, attemptRpeMigration]
        )
        #expect(result.applied == [3])

        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(attempts)").map { row -> String in
                row["name"]
            }
        }
        #expect(columns == ["id", "session_id", "climb_id", "attempt_no", "outcome", "fall_on_hold_id", "video_id", "notes", "attempted_at", "rpe"])

        // rpe is nullable with no default, so every pre-M4 attempt stays valid unrated.
        let rpeColumn = try #require(try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(attempts)").first { row in
                (row["name"] as String) == "rpe"
            }
        })
        let notNull: Int = rpeColumn["notnull"]
        #expect(notNull == 0)

        let version = try db.read { try readSchemaVersion(on: $0) }
        #expect(version == 3)
        let auditName = try db.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM schema_migrations WHERE version = 3")
        }
        #expect(auditName == "attempt_rpe")

        // The rebuilt indexes survive the rename.
        let indexes = try db.read { try indexedNames($0) }
        #expect(indexes.contains("idx_attempts_climb"))
        #expect(indexes.contains("idx_attempts_session"))
        #expect(indexes.contains("idx_attempts_session_climb"))
    }

    @Test("historical project rows are rewritten to fail with their data intact")
    func projectRowsBecomeFails() throws {
        let db = try version2Database()
        try seedOwnerChain(db, attemptRows: """
            INSERT INTO attempts (id, session_id, climb_id, attempt_no, outcome, notes, attempted_at)
            VALUES
                ('attempt-1', 'session-1', 'climb-1', 1, 'project', 'worked the crux', 't2'),
                ('attempt-2', 'session-1', 'climb-1', 2, 'fail', NULL, 't3'),
                ('attempt-3', 'session-1', 'climb-1', 3, 'flash', NULL, 't4')
        """)

        _ = try runPendingMigrations(on: db)

        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM attempts ORDER BY attempt_no")
        }
        #expect(rows.count == 3)
        #expect(rows.map { $0["outcome"] as String } == ["fail", "fail", "flash"])
        #expect(rows[0]["notes"] as String? == "worked the crux", "notes survive the rebuild")
        #expect(rows[0]["attempted_at"] as String == "t2")
        #expect(rows.map { $0["rpe"] as Int? } == [nil, nil, nil])
    }

    @Test("the rebuilt CHECK accepts rpe 1 to 10 and rejects the retired project outcome")
    func narrowedCheck() throws {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(on: db)
        try seedOwnerChain(db, attemptRows: """
            INSERT INTO attempts (id, session_id, climb_id, attempt_no, outcome, attempted_at, rpe)
            VALUES ('attempt-1', 'session-1', 'climb-1', 1, 'fail', 't2', 7)
        """)

        let stored = try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT rpe FROM attempts WHERE id = 'attempt-1'")
        }
        #expect(stored == 7)

        #expect(throws: DatabaseError.self) {
            try db.write { db in
                try db.execute(sql: """
                    INSERT INTO attempts (id, session_id, climb_id, attempt_no, outcome, attempted_at, rpe)
                    VALUES ('attempt-2', 'session-1', 'climb-1', 2, 'fail', 't3', 11)
                """)
            }
        }
        #expect(throws: DatabaseError.self) {
            try db.write { db in
                try db.execute(sql: """
                    INSERT INTO attempts (id, session_id, climb_id, attempt_no, outcome, attempted_at)
                    VALUES ('attempt-3', 'session-1', 'climb-1', 3, 'project', 't4')
                """)
            }
        }
    }
}
