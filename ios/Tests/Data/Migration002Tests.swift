import Foundation
import GRDB
import Testing
@testable import CyberSendData

// Migration 002 (M3, US-20): climb_holds join table and photos.original_uri. Empty
// upgrade, populated backfill keyed by holds.climb_id with the ordinal carried across
// as the sequence, the schema_migrations audit row and user_version mirror, and
// transaction rollback on failure.

@Suite("Migration 002 climb holds")
struct Migration002Tests {
    @Test("empty upgrade adds climb_holds, its index, and photos.original_uri")
    func emptyUpgrade() throws {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(on: db, migrations: [initialMigration])
        let before = try db.read { try tableNames($0) }
        #expect(!before.contains("climb_holds"))

        let result = try runPendingMigrations(on: db)
        #expect(result.applied == [2])

        let tables = try db.read { try tableNames($0) }
        #expect(tables.contains("climb_holds"))
        let indexes = try db.read { try indexedNames($0) }
        #expect(indexes.contains("idx_climb_holds_hold"))

        // ALTER TABLE ADD COLUMN lands as a nullable column with no default.
        let photoColumns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(photos)").map { row -> String in
                let name: String = row["name"]
                return name
            }
        }
        #expect(photoColumns.contains("original_uri"))

        // An empty database backfills no membership rows.
        let backfilled = try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM climb_holds") ?? 0
        }
        #expect(backfilled == 0)
    }

    @Test("populated holds backfill into climb_holds keyed by holds.climb_id")
    func populatedBackfill() throws {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(on: db, migrations: [initialMigration])

        // Version 1 era data inserted directly: two climbs, three holds (one without
        // an ordinal, one on the second climb).
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO gyms (id, name, is_archived, created_at, updated_at)
                VALUES ('gym-1', 'Gym', 0, 't0', 't0')
            """)
            try db.execute(sql: """
                INSERT INTO climbs (id, gym_id, is_active, is_archived, created_at, updated_at)
                VALUES ('climb-1', 'gym-1', 1, 0, 't0', 't0'), ('climb-2', 'gym-1', 1, 0, 't0', 't0')
            """)
            try db.execute(sql: """
                INSERT INTO holds (id, climb_id, x_norm, y_norm, radius_norm, source, ordinal, created_at, updated_at)
                VALUES
                    ('hold-1', 'climb-1', 0.1, 0.1, 0.02, 'manual', 1, 't1', 't1'),
                    ('hold-2', 'climb-1', 0.2, 0.2, 0.02, 'manual', NULL, 't2', 't2'),
                    ('hold-3', 'climb-2', 0.3, 0.3, 0.02, 'manual', 0, 't3', 't3')
            """)
        }

        let result = try runPendingMigrations(on: db)
        #expect(result.applied == [2])

        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM climb_holds ORDER BY hold_id")
        }
        #expect(rows.count == 3)
        let membership = rows.map { row -> (climb: String, hold: String, sequence: Int64?, createdAt: String) in
            let climb: String = row["climb_id"]
            let hold: String = row["hold_id"]
            let sequence: Int64? = row["sequence"]
            let createdAt: String = row["created_at"]
            return (climb, hold, sequence, createdAt)
        }
        // Every row mirrors its hold's climb_id, with ordinal as sequence and the
        // hold's created_at as the membership timestamp.
        #expect(membership[0].climb == "climb-1" && membership[0].hold == "hold-1")
        #expect(membership[0].sequence == 1)
        #expect(membership[0].createdAt == "t1")
        #expect(membership[1].climb == "climb-1" && membership[1].hold == "hold-2")
        #expect(membership[1].sequence == nil, "a nil ordinal backfills as a nil sequence")
        #expect(membership[1].createdAt == "t2")
        #expect(membership[2].climb == "climb-2" && membership[2].hold == "hold-3")
        #expect(membership[2].sequence == 0)
        #expect(membership[2].createdAt == "t3")

        // The hold rows themselves are untouched: origin climb and ordinal stay.
        let holds = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, climb_id, ordinal FROM holds ORDER BY id")
        }
        #expect(holds.map { $0["id"] as String } == ["hold-1", "hold-2", "hold-3"])
        #expect(holds.map { $0["climb_id"] as String } == ["climb-1", "climb-1", "climb-2"])
    }

    @Test("the audit row and user_version land for version 2")
    func auditAndUserVersion() throws {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(on: db)

        let version = try db.read { try readSchemaVersion(on: $0) }
        #expect(version == 2)
        let audit = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT version, name FROM schema_migrations WHERE version = 2")
        }
        let auditRow = try #require(audit)
        let auditVersion: Int = auditRow["version"]
        let auditName: String = auditRow["name"]
        #expect(auditVersion == 2)
        #expect(auditName == "climb_holds")
    }

    @Test("a failure during the version 2 step rolls the whole migration back")
    func rollbackOnFailure() throws {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(on: db, migrations: [initialMigration])

        // The same first step as Migration 002, then a forced failure: the runner wraps
        // each migration in one transaction, so climb_holds and the audit row vanish
        // together and the database stays on version 1.
        let failing = Migration(version: 2, name: "climb_holds") { db in
            try db.execute(sql: """
                CREATE TABLE climb_holds (
                    climb_id    TEXT NOT NULL REFERENCES climbs(id) ON DELETE CASCADE,
                    hold_id     TEXT NOT NULL REFERENCES holds(id) ON DELETE CASCADE,
                    sequence    INTEGER,
                    created_at  TEXT NOT NULL,
                    PRIMARY KEY (climb_id, hold_id)
                )
            """)
            throw ForcedMigrationFailure2()
        }

        #expect(throws: ForcedMigrationFailure2.self) {
            try runPendingMigrations(on: db, migrations: [initialMigration, failing])
        }

        let tables = try db.read { try tableNames($0) }
        #expect(!tables.contains("climb_holds"))
        let version = try db.read { try readSchemaVersion(on: $0) }
        #expect(version == 1)
        let auditCount = try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_migrations WHERE version = 2") ?? 0
        }
        #expect(auditCount == 0, "the rolled back step left no audit row")
    }
}

private struct ForcedMigrationFailure2: Error {}
