import Foundation
import GRDB
import Testing
@testable import CyberSendData

// Migration runner tests (US-7, port of src/data/db/__tests__/migrations.test.ts): empty
// database, populated database, forced failure rollback, refusal of newer databases, and
// duplicate version rejection.

@Suite("Migrations from an empty database")
struct MigrationsFromEmptyTests {
    @Test("creates the full schema and mirrors user_version")
    func createsFullSchema() throws {
        let db = try DatabaseQueue()
        let result = try runPendingMigrations(on: db)

        #expect(result.applied == defaultMigrations().map(\.version))
        let version = try db.read { try readSchemaVersion(on: $0) }
        #expect(version == currentSchemaVersion)
        #expect(result.schemaVersion == currentSchemaVersion)

        let tables = try db.read { try tableNames($0) }
        // grdb_migrations is GRDB's own runner bookkeeping; everything else is our schema.
        #expect(tables == [
            "analysis_events",
            "attempts",
            "board_problems",
            "boards",
            "climb_holds",
            "climbs",
            "grade_levels",
            "grade_norm_params",
            "grade_systems",
            "grdb_migrations",
            "gyms",
            "holds",
            "photos",
            "pose_keypoints",
            "schema_migrations",
            "sessions",
            "settings",
            "video_analyses",
            "videos",
            "walls",
        ])

        let recorded = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT version, name FROM schema_migrations ORDER BY version")
        }
        #expect(recorded.count == defaultMigrations().count)
        let recordedVersions = recorded.map { $0["version"] as Int }
        let recordedNames = recorded.map { $0["name"] as String }
        #expect(recordedVersions == defaultMigrations().map(\.version))
        #expect(recordedNames == defaultMigrations().map(\.name))
    }

    @Test("seeds the built-in grade systems with ordered levels")
    func seedsBuiltinGradeSystems() throws {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(on: db)

        let seeded = try db.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT grade_systems.id AS system_id, is_builtin, COUNT(grade_levels.id) AS level_count
                FROM grade_systems JOIN grade_levels ON grade_levels.system_id = grade_systems.id
                GROUP BY grade_systems.id ORDER BY grade_systems.id
                """
            )
        }
        #expect(seeded.count == 2)
        let byID = Dictionary(uniqueKeysWithValues: seeded.map { row -> (String, Int) in
            let id: String = row["system_id"]
            let count: Int = row["level_count"]
            return (id, count)
        })
        #expect(byID["v_scale"] == 18)
        #expect(byID["font"] == 26)
        for row in seeded {
            let builtin: Bool = row["is_builtin"]
            #expect(builtin)
        }

        let firstLevel = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT label, rank_order FROM grade_levels WHERE id = 'v0'")
        }
        let label: String = firstLevel!["label"]
        let rank: Int = firstLevel!["rank_order"]
        #expect(label == "V0")
        #expect(rank == 0)
    }

    @Test("is idempotent: a second run applies nothing")
    func secondRunAppliesNothing() throws {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(on: db)
        let second = try runPendingMigrations(on: db)

        #expect(second.applied.isEmpty)
        let version = try db.read { try readSchemaVersion(on: $0) }
        #expect(version == currentSchemaVersion)
        let recorded = try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_migrations") ?? 0
        }
        #expect(recorded == Int64(defaultMigrations().count))
    }

    @Test("every index from docs/schema.sql exists")
    func everyIndexExists() throws {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(on: db)
        let indexes = try db.read { try indexedNames($0) }
        #expect(indexes == [
            "idx_analysis_events_analysis",
            "idx_attempts_climb",
            "idx_attempts_session",
            "idx_attempts_session_climb",
            "idx_climb_holds_hold",
            "idx_climbs_gym",
            "idx_climbs_gym_status",
            "idx_grade_levels_system",
            "idx_gradenorm_scope",
            "idx_holds_climb",
            "idx_photos_climb",
            "idx_photos_session",
            "idx_pose_video_t",
            "idx_sessions_gym_started",
            "idx_video_analyses_video",
            "idx_videos_retention",
            "idx_videos_session",
            "idx_walls_gym",
        ])
    }
}

@Suite("Migrations on a populated database")
struct MigrationsOnPopulatedTests {
    @Test("applies later migrations without losing data")
    func appliesLaterMigrations() throws {
        let test = try makeTestDatabase()
        let (gymId, climbId) = try seedGymAndClimb(test.repos)

        // Derived, not hardcoded: the next version after everything this build ships.
        let nextVersion = currentSchemaVersion + 1
        let addsColumn = Migration(version: nextVersion, name: "test_add_column") { db in
            try db.execute(sql: "ALTER TABLE climbs ADD COLUMN nickname TEXT")
        }
        let second = try runPendingMigrations(on: test.writer, migrations: defaultMigrations() + [addsColumn])

        #expect(second.applied == [nextVersion])
        let version = try test.writer.read { try readSchemaVersion(on: $0) }
        #expect(version == nextVersion)
        let loaded = try test.repos.climbs.get(id: climbId)
        #expect(loaded?.name == "Blue V4")
        #expect(loaded?.gymId == gymId)
        let recorded = try test.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT version FROM schema_migrations ORDER BY version")
        }
        #expect(recorded == defaultMigrations().map { Int64($0.version) } + [Int64(nextVersion)])
    }
}

@Suite("Migration failure handling")
struct MigrationFailureTests {
    @Test("a failing migration rolls back and leaves the prior schema intact")
    func failingMigrationRollsBack() throws {
        let db = try DatabaseQueue()
        _ = try runPendingMigrations(on: db)

        let failing = Migration(version: currentSchemaVersion + 1, name: "test_failing") { db in
            try db.execute(sql: "CREATE TABLE half_done (id TEXT PRIMARY KEY)")
            throw ForcedMigrationFailure()
        }

        #expect(throws: ForcedMigrationFailure.self) {
            try runPendingMigrations(on: db, migrations: defaultMigrations() + [failing])
        }

        let tables = try db.read { try tableNames($0) }
        #expect(!tables.contains("half_done"))
        let version = try db.read { try readSchemaVersion(on: $0) }
        #expect(version == currentSchemaVersion)
        let recorded = try db.read { db in
            try Int64.fetchAll(db, sql: "SELECT version FROM schema_migrations ORDER BY version")
        }
        #expect(recorded == defaultMigrations().map { Int64($0.version) })
    }

    @Test("a database newer than the app is refused with restore guidance (US-7.4)")
    func newerDatabaseRefused() throws {
        let db = try DatabaseQueue()
        try db.write { try $0.execute(sql: "PRAGMA user_version = 99") }

        let error = #expect(throws: MigrationError.self) {
            try runPendingMigrations(on: db)
        }
        guard case .databaseNewerThanApp(let databaseVersion, let appVersion) = error else {
            Issue.record("Expected databaseNewerThanApp, got \(String(describing: error))")
            return
        }
        #expect(databaseVersion == 99)
        #expect(appVersion == currentSchemaVersion)
        #expect(error?.description.contains("newer version of CyberSend") ?? false)
        #expect(error?.description.contains("restore a backup") ?? false)
    }

    @Test("duplicate migration versions are rejected before GRDB sees them")
    func duplicateVersionsRejected() throws {
        let db = try DatabaseQueue()
        let duplicate = Migration(version: 1, name: "dup") { _ in }

        let error = #expect(throws: MigrationError.self) {
            try runPendingMigrations(on: db, migrations: defaultMigrations() + [duplicate])
        }
        guard case .duplicateVersion(let version) = error else {
            Issue.record("Expected duplicateVersion, got \(String(describing: error))")
            return
        }
        #expect(version == 1)
        #expect(error?.description == "Duplicate migration version: 1")
    }

    @Test("invalid migration versions are rejected")
    func invalidVersionsRejected() throws {
        let db = try DatabaseQueue()
        let invalid = Migration(version: 0, name: "zero") { _ in }
        let error = #expect(throws: MigrationError.self) {
            try runPendingMigrations(on: db, migrations: defaultMigrations() + [invalid])
        }
        guard case .invalidVersion = error else {
            Issue.record("Expected invalidVersion, got \(String(describing: error))")
            return
        }
    }
}

private struct ForcedMigrationFailure: Error {}
