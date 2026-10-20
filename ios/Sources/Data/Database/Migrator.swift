import CyberSendDomain
import Foundation
import GRDB

// Ordered forward only migrations (port of src/data/db/migrations/index.ts, adapted to GRDB's
// DatabaseMigrator per docs/decisions.md: DatabaseMigrator is the runner of record and each
// migration block also writes one schema_migrations audit row in the same transaction, keeping
// the US-7 audit format). There are no down migrations; restore from a backup is the rollback
// path.

public struct Migration: Sendable {
    public let version: Int
    public let name: String
    public let up: @Sendable (Database) throws -> Void

    public init(version: Int, name: String, up: @escaping @Sendable (Database) throws -> Void) {
        self.version = version
        self.name = name
        self.up = up
    }

    /// GRDB identifies migrations by string; the numeric version leads so registration order
    /// matches the version order.
    public var identifier: String { "\(version)_\(name)" }
}

public enum MigrationError: Error, Equatable, CustomStringConvertible {
    case invalidVersion(Int)
    case duplicateVersion(Int)
    case databaseNewerThanApp(databaseVersion: Int, appVersion: Int)

    public var description: String {
        switch self {
        case .invalidVersion(let version):
            return "Invalid migration version: \(version)"
        case .duplicateVersion(let version):
            return "Duplicate migration version: \(version)"
        case .databaseNewerThanApp(let databaseVersion, let appVersion):
            return "This database was created by a newer version of CyberSend (schema \(databaseVersion), this app runs schema \(appVersion)). Update the app, or restore a backup taken with this version."
        }
    }
}

extension MigrationError: LocalizedError {
    public var errorDescription: String? { description }
}

public struct MigrationRunResult: Equatable, Sendable {
    public let applied: [Int]
    public let schemaVersion: Int

    public init(applied: [Int], schemaVersion: Int) {
        self.applied = applied
        self.schemaVersion = schemaVersion
    }
}

/// The migrations this build knows how to run.
public func defaultMigrations() -> [Migration] {
    [initialMigration]
}

/// The schema version of the newest migration this build ships (US-7.4: newer databases are
/// refused with restore guidance).
public let currentSchemaVersion: Int = defaultMigrations().map(\.version).max() ?? 0

/// Reads PRAGMA user_version, the mirrored schema version (GRDB 7 removed its userVersion
/// helpers, so the pragma is read directly; it is a validated statement, never user input).
public func readSchemaVersion(on db: Database) throws -> Int {
    let value = try Int64.fetchOne(db, sql: "PRAGMA user_version")
    return value.map(Int.init) ?? 0
}

/// Sorted ascending with unique, positive, integer versions. Mirrors the TypeScript
/// assert_well_formed; duplicate versions are rejected before GRDB sees the migrations
/// (GRDB's own duplicate detection is a precondition failure, not a catchable error).
func assertWellFormed(_ migrations: [Migration]) throws -> [Migration] {
    var seen = Set<Int>()
    let sorted = migrations.sorted { $0.version < $1.version }
    for migration in sorted {
        guard migration.version >= 1 else {
            throw MigrationError.invalidVersion(migration.version)
        }
        guard seen.insert(migration.version).inserted else {
            throw MigrationError.duplicateVersion(migration.version)
        }
    }
    return sorted
}

/// Applies every migration with a version above the database's current PRAGMA user_version.
/// migrations is injectable so tests can exercise failure rollback and populated DB upgrades
/// against the same runner the app uses (port of run_pending_migrations).
public func runPendingMigrations(
    on writer: any DatabaseWriter,
    migrations: [Migration] = defaultMigrations()
) throws -> MigrationRunResult {
    let ordered = try assertWellFormed(migrations)
    let latest = ordered.last?.version ?? 0
    let userVersion = try writer.read { db in
        try readSchemaVersion(on: db)
    }
    guard userVersion <= latest else {
        throw MigrationError.databaseNewerThanApp(databaseVersion: userVersion, appVersion: latest)
    }

    var migrator = DatabaseMigrator()
    var applied: [Int] = []
    for migration in ordered where migration.version > userVersion {
        let body = migration.up
        migrator.registerMigration(migration.identifier) { db in
            try body(db)
            // US-7 audit row in the same transaction as the migration body (dual write with
            // GRDB's own grdb_migrations bookkeeping).
            try db.execute(
                sql: "INSERT OR REPLACE INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)",
                arguments: [migration.version, migration.name, nowISO8601()]
            )
            // PRAGMA does not accept bound parameters. The version is a validated integer from
            // our own migration list, never user input, so interpolation is safe.
            try db.execute(sql: "PRAGMA user_version = \(migration.version)")
        }
        applied.append(migration.version)
    }
    try migrator.migrate(writer)
    return MigrationRunResult(applied: applied, schemaVersion: max(userVersion, latest))
}
