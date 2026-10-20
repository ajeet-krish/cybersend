import CyberSendData
import CyberSendFeatures
import SQLite3
import XCTest
@testable import CyberSend

// Launch state mapping smoke (docs/architecture.md: app level XCTest covers the
// composition root and launch states; docs/requirements.md US-7.4: older app plus newer
// database is refused with guidance and no writes).

@MainActor
final class LaunchStateTests: XCTestCase {
    func testNewerDatabaseMapsToNewerDatabaseState() throws {
        let root = try makeTemporaryRoot(label: "newer-database")
        defer { removeTemporaryRoot(root) }

        // Pre set the temp database file to a future schema version, exactly like a
        // database written by a newer app, then let the default opener discover it.
        let futureVersion = currentSchemaVersion + 5
        try Self.seedFutureUserVersion(at: root, version: futureVersion)

        let result = AppBootstrap(documentDirectory: root, variant: .development).run()

        XCTAssertEqual(
            result.state,
            .newerDatabase(databaseVersion: futureVersion, appVersion: currentSchemaVersion)
        )
        XCTAssertNil(result.environment, "no environment is built when the database is refused")

        // US-7.4 zero write proof: reopen the seeded file and assert nothing changed.
        // The future user_version is intact and no table (grdb_migrations,
        // schema_migrations, or user schema) was created by the refusal.
        let after = try Self.readDatabaseState(at: root)
        XCTAssertEqual(after.userVersion, futureVersion, "the refusal must not touch user_version")
        XCTAssertEqual(after.tableCount, 0, "the refusal must not create any table")
    }

    func testInjectedMigrationErrorMapsToMigrationFailed() throws {
        let root = try makeTemporaryRoot(label: "failed-migration")
        defer { removeTemporaryRoot(root) }

        let bootstrap = AppBootstrap(documentDirectory: root, variant: .development) { _ in
            throw MigrationError.invalidVersion(0)
        }
        let result = bootstrap.run()

        guard case .migrationFailed(let message) = result.state else {
            return XCTFail("expected migrationFailed, got \(result.state)")
        }
        XCTAssertTrue(message.contains("Invalid migration version"), message)
        XCTAssertNil(result.environment)
    }

    func testInjectedUnexpectedErrorMapsToMigrationFailed() throws {
        struct StorageFailure: LocalizedError {
            var errorDescription: String? { "The logbook storage is unavailable." }
        }

        let root = try makeTemporaryRoot(label: "storage-failure")
        defer { removeTemporaryRoot(root) }

        let bootstrap = AppBootstrap(documentDirectory: root, variant: .development) { _ in
            throw StorageFailure()
        }
        let result = bootstrap.run()

        XCTAssertEqual(result.state, .migrationFailed(message: "The logbook storage is unavailable."))
        XCTAssertNil(result.environment)
    }

    func testRetryAfterFailureRecoversWhenTheOpenerSucceeds() throws {
        let root = try makeTemporaryRoot(label: "retry")
        defer { removeTemporaryRoot(root) }

        var shouldFail = true
        let bootstrap = AppBootstrap(documentDirectory: root, variant: .development) { url in
            if shouldFail {
                throw MigrationError.invalidVersion(0)
            }
            let opened = try CyberSendDatabase.openDeviceDatabase(at: url)
            return (
                Repositories(writer: opened.writer),
                opened.migration,
                BackupProcedures.unavailable("Injected opener tests never restore.")
            )
        }

        XCTAssertEqual(bootstrap.run().state, .migrationFailed(message: "Invalid migration version: 0"))

        shouldFail = false
        let recovered = bootstrap.run()
        XCTAssertEqual(recovered.state, .ready)
        XCTAssertNotNil(recovered.environment)
    }

    /// Creates root/db/cybersend.sqlite containing nothing but a PRAGMA user_version above
    /// this build's schema, the state a newer app leaves behind.
    private static func seedFutureUserVersion(at root: URL, version: Int) throws {
        let directory = root.appendingPathComponent(CyberSendDatabase.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(CyberSendDatabase.filename).path

        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let handle = db else {
            sqlite3_close(db)
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(handle) }
        let sql = "PRAGMA user_version = \(version)"
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Reopens the database file directly (raw SQLite, no migration path) and reads the
    /// two facts the zero write guarantee covers: PRAGMA user_version and the user table
    /// count from sqlite_master.
    private static func readDatabaseState(at root: URL) throws -> (userVersion: Int, tableCount: Int) {
        let path = root
            .appendingPathComponent(CyberSendDatabase.directoryName, isDirectory: true)
            .appendingPathComponent(CyberSendDatabase.filename).path

        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let handle = db else {
            sqlite3_close(db)
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(handle) }

        return (
            userVersion: try scalar("PRAGMA user_version", on: handle),
            tableCount: try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'", on: handle)
        )
    }

    /// The first column of the first row of a single value query, read through the C API
    /// callback so no test only module dependency is needed.
    private static func scalar(_ sql: String, on handle: OpaquePointer) throws -> Int {
        var value = -1
        let status = sqlite3_exec(
            handle,
            sql,
            { context, _, argv, _ in
                guard let context, let first = argv?[0] else { return SQLITE_OK }
                context.assumingMemoryBound(to: Int.self).pointee = Int(String(cString: first)) ?? -1
                return SQLITE_OK
            },
            &value,
            nil
        )
        guard status == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
}
