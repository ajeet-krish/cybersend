import Foundation
import GRDB
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// M2 housekeeping from the M1 review: zip unpack caps, the export side safe uri guard,
// the repository owned foreign key check, the tolerant throttle clock, and the new
// settings keys. The golden fixture byte tests live in ExportSerializeTests and stay
// untouched by these changes.

@Suite("M2 housekeeping")
struct HousekeepingTests {
    @Test("unpack enforces the entry count and inflated size caps")
    func unpackEnforcesCaps() throws {
        // The shipped defaults are 10000 entries and 4 GiB of inflated data.
        #expect(UnpackLimits().maxEntries == 10_000)
        #expect(UnpackLimits().maxTotalInflatedBytes == 4 * 1024 * 1024 * 1024)

        let manifest = BackupManifest(
            app: exportAppID,
            appVersion: "1.0.0",
            schemaVersion: currentSchemaVersion,
            createdAt: fixtureExportTime,
            media: []
        )
        let bytes = try packBackup(BackupArchive(
            manifest: manifest,
            data: String(repeating: "x", count: 4_096),
            media: [:]
        ))

        // Inside the caps an ordinary archive unpacks (manifest.json plus data.json).
        let archive = try unpackBackup(bytes)
        #expect(archive.data.count == 4_096)

        // Too many entries: the second entry trips a cap of one, before it is extracted.
        let entryError = #expect(throws: BackupArchiveError.self) {
            try unpackBackup(bytes, limits: UnpackLimits(maxEntries: 1))
        }
        #expect(entryError?.message.contains("limit 1") == true)
        #expect(entryError?.message.contains("Nothing was restored.") == true)

        // Too much inflated data: the declared size of the first entry is rejected
        // before any bytes are appended to memory.
        let sizeError = #expect(throws: BackupArchiveError.self) {
            try unpackBackup(bytes, limits: UnpackLimits(maxTotalInflatedBytes: 16))
        }
        #expect(sizeError?.message.contains("limit 16 bytes") == true)
        #expect(sizeError?.message.contains("Nothing was restored.") == true)
    }

    @Test("export skips unsafe media uris with a warning")
    func exportSkipsUnsafeMediaUri() throws {
        let test = try makeTestDatabase()
        let root = try housekeepingTempDirectory()

        var rows = goldenSeedRows()
        rows[.photos]?.append(exportRow(.photos, [
            "id": .text("photo-evil"),
            "climb_id": .text("climb-1"),
            "uri": .text("../evil"),
            "width": .integer(100),
            "height": .integer(100),
            "source": .text("camera"),
            "captured_at": .text(fixtureSeedTime),
            "created_at": .text(fixtureSeedTime),
        ]))
        try seedDatabase(test.writer, repos: test.repos, rows: rows)

        // The hostile file really exists just outside the document root, so only the
        // path guard keeps it out of the archive.
        let outside = root.deletingLastPathComponent().appendingPathComponent("evil")
        try Data("evil bytes".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        // The safe photo exists inside the root and must still travel.
        let photoURL = root.appendingPathComponent("photos/photo-1.jpg")
        try FileManager.default.createDirectory(
            at: photoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x01, 0x02]).write(to: photoURL)

        var warnings: [String] = []
        let bytes = try buildBackupBytes(
            repos: test.repos,
            documentRoot: root,
            appVersion: "1.0.0",
            now: fixtureExportTime,
            onWarning: { warnings.append($0) }
        )
        let archive = try unpackBackup(bytes)

        #expect(archive.media.keys.sorted() == ["photos/photo-1.jpg"], "only the safe photo travels")
        #expect(archive.manifest.media.map(\.path) == ["photos/photo-1.jpg"])
        #expect(warnings.count == 1, "one warning for the one unsafe uri")
        #expect(warnings[0].contains("../evil"))
        #expect(warnings[0].contains("not a safe file path"))
    }

    @Test("foreignKeyCheck reports a seeded violation (repository owned SQL)")
    func foreignKeyCheckFindsSeededViolation() throws {
        // A clean migrated database passes the check.
        let clean = try makeTestDatabase()
        let intact = try clean.writer.read { db in
            try clean.repos.dump.foreignKeyCheck(on: db)
        }
        #expect(intact.isEmpty)

        let test = try makeTestDatabase()
        // Seed an orphan session with enforcement off. SQLite ignores the pragma inside
        // a transaction, so the seed runs outside one and enforcement is restored right
        // after.
        try test.writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: """
            INSERT INTO sessions (id, gym_id, started_at, created_at, updated_at)
            VALUES ('session-orphan', 'missing-gym', '2026-10-01T00:00:00.000Z',
                    '2026-10-01T00:00:00.000Z', '2026-10-01T00:00:00.000Z')
            """)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let violations = try test.writer.read { db in
            try test.repos.dump.foreignKeyCheck(on: db)
        }
        #expect(violations.count == 1, "the orphan session is reported exactly once")
        #expect(violations.first?.table == "sessions")
        #expect(violations.first?.parentTable == "gyms")

        // The import service maps that result to the plain-language import failure.
        let payload = buildExportPayload(
            dump: [.sessions: [exportRow(.sessions, [
                "id": .text("session-import"),
                "gym_id": .text("another-missing-gym"),
                "started_at": .text(fixtureSeedTime),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ])]],
            schemaVersion: currentSchemaVersion,
            exportedAt: fixtureExportTime
        )
        let error = #expect(throws: ImportPayloadError.self) {
            try importPayloadJSON(serializeExportPayload(payload), on: test.writer)
        }
        #expect(error?.message == "The file contains rows that break foreign key links. Nothing was imported.")
    }

    @Test("the throttle clock accepts both ISO 8601 shapes and rejects a bad injected time")
    func throttleClockParsing() throws {
        let test = try makeTestDatabase()
        let root = try housekeepingTempDirectory()

        // A stored stamp without fractional seconds still throttles (it used to fail
        // the fractional only parser and silently disable the throttle).
        try test.repos.settings.set(key: settingsKeyLastBackupAt, valueJson: "\"2026-10-19T12:00:00Z\"")

        // Plain now against the plain stamp: within the hour, throttled.
        #expect(try maybeWriteAutomaticBackup(
            repos: test.repos,
            documentDirectory: root,
            trigger: .appBackground,
            now: "2026-10-19T12:30:00Z"
        ) == false)

        // Fractional now against the plain stamp: still within the hour, throttled.
        #expect(try maybeWriteAutomaticBackup(
            repos: test.repos,
            documentDirectory: root,
            trigger: .appBackground,
            now: "2026-10-19T12:59:59.500Z"
        ) == false)

        // Past the hour the plain shape writes again.
        #expect(try maybeWriteAutomaticBackup(
            repos: test.repos,
            documentDirectory: root,
            trigger: .appBackground,
            now: "2026-10-19T13:00:01Z"
        ) == true)
        #expect(try listBackups(at: root).count == 1)

        // An unparseable injected clock fails explicitly instead of the old Date()
        // fallback, and it writes nothing.
        let error = #expect(throws: BackupClockError.self) {
            try maybeWriteAutomaticBackup(
                repos: test.repos,
                documentDirectory: root,
                trigger: .appBackground,
                now: "not-a-timestamp"
            )
        }
        #expect(error?.message.contains("not a valid ISO 8601") == true)
        #expect(error?.message.contains("Nothing was backed up.") == true)
        #expect(try listBackups(at: root).count == 1, "the rejected call wrote no backup")

        // The wall-clock default path stays intact: an omitted now writes normally.
        #expect(try maybeWriteAutomaticBackup(
            repos: test.repos,
            documentDirectory: root,
            trigger: .sessionClose
        ) == true)
    }

    @Test("appearance and photo retention settings keys hold export safe values")
    func newSettingsKeysRoundTrip() throws {
        #expect(settingsKeyAppearance == "ui.appearance")
        #expect(settingsKeyPhotoRetention == "photo.retention")
        #expect(AppearancePreference.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(PhotoRetentionPreference.allCases.map(\.rawValue) == ["keep_originals", "discard_originals"])

        let test = try makeTestDatabase()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())
        try test.repos.settings.setJSON(key: settingsKeyAppearance, value: AppearancePreference.dark.rawValue)
        try test.repos.settings.setJSON(
            key: settingsKeyPhotoRetention,
            value: PhotoRetentionPreference.keepOriginals.rawValue
        )
        #expect(try test.repos.settings.getJSON(key: settingsKeyAppearance, as: String.self) == "dark")

        // Settings rows are free form: the export table set is unchanged and both new
        // keys ride along as ordinary settings rows.
        let json = try buildExportJSON(repos: test.repos, now: fixtureExportTime)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let tables = try #require(object["tables"] as? [String: Any])
        #expect(Set(tables.keys) == Set(ExportTable.allCases.map(\.rawValue)))
        let settingsRows = try #require(tables["settings"] as? [[String: Any]])
        #expect(settingsRows.contains { $0["key"] as? String == "ui.appearance" })
        #expect(settingsRows.contains { $0["key"] as? String == "photo.retention" })

        // And they round trip into a fresh database through the import path.
        let target = try makeTestDatabase()
        _ = try importPayloadJSON(json, on: target.writer)
        #expect(try target.repos.settings.getJSON(
            key: settingsKeyPhotoRetention,
            as: String.self
        ) == "keep_originals")
    }
}

/// A fresh temporary directory per call, cleaned up when the test process exits.
private func housekeepingTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cybersend_housekeeping_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
