import Foundation
import GRDB

// Device database connection (port of src/data/db/connection.ts and pragmas.ts, adapted to
// GRDB per docs/decisions.md). GRDB enables foreign_keys on every connection and a
// DatabasePool runs in WAL mode, which matches the TypeScript OPEN_PRAGMAS exactly;
// busy_timeout is set on the configuration.

public enum CyberSendDatabase {
    public static let filename = "cybersend.sqlite"
    public static let directoryName = "db"

    /// Opens (or creates) the on-device database under the given document directory and runs
    /// pending migrations. Call once at app launch (M1); M0 uses the in-memory test database.
    public static func openDeviceDatabase(at documentDirectory: URL) throws -> (writer: DatabasePool, migration: MigrationRunResult) {
        let directory = documentDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(path: directory.appendingPathComponent(filename).path, configuration: configuration)
        let migration = try runPendingMigrations(on: pool)
        return (pool, migration)
    }

    /// Hermetic in-memory database for DataTests (docs/tests.md: DataTests run on in-memory
    /// GRDB), migrated through the same runner the app uses.
    public static func makeTestDatabase() throws -> (writer: DatabaseQueue, migration: MigrationRunResult) {
        let queue = try DatabaseQueue()
        let migration = try runPendingMigrations(on: queue)
        return (queue, migration)
    }
}
