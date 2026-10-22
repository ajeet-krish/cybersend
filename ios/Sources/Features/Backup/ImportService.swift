import CyberSendData
import CyberSendDomain
import Foundation
import GRDB

// Import service (port of src/features/backup/import_service.ts plus the media and
// staging work from the restore path). Order of operations guarantees zero writes on
// any failure: 1. parse JSON, 2. validate every row strictly, 3. reject newer schema
// versions, 4. migrate older payload versions forward and re-validate the migrated
// rows, 5. rehearse the full load in a
// throwaway staging database, 6. only then open one transaction that upserts every
// table and runs foreign_key_check before commit. Re-import is idempotent: upserts key
// on stable ids (US-16.4).

/// A payload level schema upgrade (port of PayloadMigration). The registry this build
/// ships lives in defaultPayloadMigrations (version 1 to 2 for the M3 climb_holds
/// payload); tests can inject their own steps through ImportOptions so future schema
/// versions have a proven path (US-16.2).
public struct PayloadMigration: Sendable {
    public let from: Int
    public let migrate: @Sendable (ParsedImportPayload) throws -> ParsedImportPayload

    public init(from: Int, migrate: @escaping @Sendable (ParsedImportPayload) throws -> ParsedImportPayload) {
        self.from = from
        self.migrate = migrate
    }
}

/// The payload migrations this build registers. Version 1 to 2 (M3, US-20) synthesizes
/// the climb_holds membership rows from each hold's origin climb and stamps
/// photos.original_uri as null; legacy TypeScript payloads translate to version 1
/// column shape during parsing and pass through the same step. Version 2 to 3 (M4) stamps
/// attempts.rpe null and rewrites the retired project outcome to fail. Version 3 to 4 (Problems
/// catalog) stamps climbs.notes null. Version 4 to 5 (UI overhaul) stamps climbs.categories
/// null. Version 5 to 6 (Pose v1) adds the pose analysis tables as empty.
public let defaultPayloadMigrations: [PayloadMigration] = [
    PayloadMigration(from: 1, migrate: migrateV1PayloadToV2),
    PayloadMigration(from: 2, migrate: migrateV2PayloadToV3),
    PayloadMigration(from: 3, migrate: migrateV3PayloadToV4),
    PayloadMigration(from: 4, migrate: migrateV4PayloadToV5),
    PayloadMigration(from: 5, migrate: migrateV5PayloadToV6),
]

public struct ImportOptions: Sendable {
    public var currentVersion: Int
    public var payloadMigrations: [PayloadMigration]

    public init(
        currentVersion: Int = currentSchemaVersion,
        payloadMigrations: [PayloadMigration] = defaultPayloadMigrations
    ) {
        self.currentVersion = currentVersion
        self.payloadMigrations = payloadMigrations
    }
}

/// Media files restored from, verified against, or skipped during a restore.
public struct MediaReconcileReport: Equatable, Sendable {
    public let restored: Int
    public let verified: Int
    public let skipped: Int

    public init(restored: Int = 0, verified: Int = 0, skipped: Int = 0) {
        self.restored = restored
        self.verified = verified
        self.skipped = skipped
    }
}

public struct ImportReport: Equatable, Sendable {
    public let schemaVersion: Int
    public let migratedFrom: Int?
    public let upserts: UpsertReport
    /// Legacy translation notes and media reconciliation warnings.
    public var warnings: [String]
    public var media: MediaReconcileReport

    public init(
        schemaVersion: Int,
        migratedFrom: Int? = nil,
        upserts: UpsertReport,
        warnings: [String] = [],
        media: MediaReconcileReport = MediaReconcileReport()
    ) {
        self.schemaVersion = schemaVersion
        self.migratedFrom = migratedFrom
        self.upserts = upserts
        self.warnings = warnings
        self.media = media
    }

    /// Rows that did not exist before this import (US-16 counts).
    public var restoredRows: Int {
        upserts.values.reduce(0) { $0 + $1.inserted }
    }

    /// Rows that already existed and were updated in place, never duplicated.
    public var updatedRows: Int {
        upserts.values.reduce(0) { $0 + $1.updated }
    }
}

/// Applies payload migrations step by step up to targetVersion (port of
/// migrate_payload). A missing or repeated step aborts with a plain-language error.
/// The returned payload carries targetVersion like the TypeScript migrate_payload, and
/// its rows are re-validated against the table specs before anything can write (the
/// TypeScript import_payload_json re-validates with export_payload_schema right after
/// migrating), so a migration that mangles a row fails with the same strict,
/// zero-writes semantics as the initial parse.
public func migratePayload(
    _ payload: ParsedImportPayload,
    migrations: [PayloadMigration],
    targetVersion: Int
) throws -> ParsedImportPayload {
    var current = payload
    var version = payload.schemaVersion
    var visited = Set<Int>()
    while version < targetVersion {
        guard let step = migrations.first(where: { $0.from == version }), !visited.contains(version) else {
            throw ImportPayloadError(importCannotUpgradeMessage(
                fileVersion: payload.schemaVersion,
                targetVersion: targetVersion
            ))
        }
        visited.insert(version)
        current = try step.migrate(current)
        version += 1
    }
    let stamped = ParsedImportPayload(
        schemaVersion: targetVersion,
        exportedAt: current.exportedAt,
        legacyShape: current.legacyShape,
        tables: current.tables,
        warnings: current.warnings
    )
    try validateMigratedPayload(stamped)
    return stamped
}

/// Imports one export payload (data.json text or full JSON export) into the writer.
public func importPayloadJSON(
    _ json: String,
    on writer: any DatabaseWriter,
    options: ImportOptions = ImportOptions()
) throws -> ImportReport {
    // 1 to 4: parse, validate, version check, migrate. Pure, zero writes.
    let parsed = try parseExportPayload(json)
    if parsed.schemaVersion > options.currentVersion {
        throw ImportVersionError(importNewerVersionMessage(
            fileVersion: parsed.schemaVersion,
            currentVersion: options.currentVersion
        ))
    }
    var payload = parsed
    var migratedFrom: Int?
    if parsed.schemaVersion < options.currentVersion {
        migratedFrom = parsed.schemaVersion
        payload = try migratePayload(
            parsed,
            migrations: options.payloadMigrations,
            targetVersion: options.currentVersion
        )
    }

    // 5: rehearsal. A staging database runs the identical upserts and foreign key check
    // so a bad file is rejected before the live transaction starts.
    try runStagingLoad(payload.tables)

    // 6: one transaction applies every table so a mid-import failure rolls back
    // completely (US-16.3 zero writes).
    let dump = GRDBDumpRepository(writer: writer)
    let tables = payload.tables
    let upserts: UpsertReport
    do {
        upserts = try withTransaction(on: writer) { db in
            let report = try dump.upsertAll(tables, on: db)
            try assertForeignKeysIntact(dump, on: db)
            return report
        }
    } catch let error as ImportPayloadError {
        throw error
    } catch {
        throw mappedImportConstraintError(error)
    }

    return ImportReport(
        schemaVersion: options.currentVersion,
        migratedFrom: migratedFrom,
        upserts: upserts,
        warnings: payload.warnings
    )
}

private func runStagingLoad(_ tables: [ExportTable: [ExportRow]]) throws {
    let staging = try DatabaseQueue()
    _ = try runPendingMigrations(on: staging)
    let dump = GRDBDumpRepository(writer: staging)
    do {
        try withTransaction(on: staging) { db in
            _ = try dump.upsertAll(tables, on: db)
            try assertForeignKeysIntact(dump, on: db)
        }
    } catch let error as ImportPayloadError {
        throw error
    } catch {
        throw mappedImportConstraintError(error)
    }
}

/// Runs the dump repository's foreign key check and maps any violation to the
/// plain-language import error (US-16.3). The SQL lives in DumpRepository; this layer
/// only decides what a failed check means for the restore.
private func assertForeignKeysIntact(_ dump: any DumpRepository, on db: Database) throws {
    let violations = try dump.foreignKeyCheck(on: db)
    if !violations.isEmpty {
        throw ImportPayloadError(importForeignKeyMessage)
    }
}

/// Reconciles archive media with the document root after a data import: files the
/// manifest lists are verified against their sha256, missing or diverged files are
/// restored from the archive, and anything unverifiable is skipped with a warning.
/// Media problems never fail the restore: the data already committed atomically.
public func reconcileMedia(
    manifestEntries: [BackupManifestMediaEntry],
    archiveMedia: [String: Data],
    at documentRoot: URL
) -> (report: MediaReconcileReport, warnings: [String]) {
    var restored = 0
    var verified = 0
    var skipped = 0
    var warnings: [String] = []

    for entry in manifestEntries {
        guard isSafeRelativePath(entry.path) else {
            skipped += 1
            warnings.append("The manifest listed '\(entry.path)', which is not a safe file path. It was skipped.")
            continue
        }
        let fileURL = documentRoot.appendingPathComponent(entry.path)
        let existingHash = (try? Data(contentsOf: fileURL)).map(sha256Hex)
        if existingHash == entry.sha256 {
            verified += 1
            continue
        }
        guard let archiveBytes = archiveMedia[entry.path], sha256Hex(archiveBytes) == entry.sha256 else {
            skipped += 1
            warnings.append("'\(entry.path)' was listed in the manifest but is missing or corrupt in the archive. It was skipped.")
            continue
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try archiveBytes.write(to: fileURL, options: .atomic)
            restored += 1
        } catch {
            skipped += 1
            warnings.append("'\(entry.path)' could not be written (\(error.localizedDescription)). It was skipped.")
        }
    }

    let unlisted = Set(archiveMedia.keys).subtracting(manifestEntries.map(\.path))
    if !unlisted.isEmpty {
        warnings.append("The archive contains media files that the manifest does not list; they were ignored.")
    }

    return (MediaReconcileReport(restored: restored, verified: verified, skipped: skipped), warnings)
}

/// Rejects absolute paths and path traversal so a hostile archive cannot write outside
/// the document root.
func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/") else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !components.contains("..")
}
