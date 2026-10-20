import Foundation
import GRDB
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Rotating backups and restore (US-15, US-16): last 10 retained, hourly throttle for
// the background trigger, atomic restore with pre-import snapshot and media
// reconciliation.

@Suite("Backup service")
struct BackupServiceTests {
    @Test("rotation keeps the newest 10 (US-15.2)")
    func rotationKeepsNewestTen() {
        let names = (1 ... 13).map { String(format: "backup_2026-10-%02dT00-00-00-000Z.cybersend", $0) }
        let deleted = backupsToDelete(names: names)
        #expect(deleted.count == 3)
        #expect(deleted.sorted() == names.sorted().prefix(3).map { $0 })

        // A full set is untouched; lexicographic order is chronological for ISO slugs.
        let keep = (1 ... 10).map { String(format: "backup_2026-10-%02dT00-00-00-000Z.cybersend", $0) }
        #expect(backupsToDelete(names: keep).isEmpty)

        // Pure helper: names to delete are the oldest beyond keep.
        #expect(backupsToDelete(names: keep, keep: 4).sorted() == keep.sorted().prefix(6).map { $0 })
    }

    @Test("writeBackup writes one archive, rotates, and records the settings stamp")
    func writeBackupRotatesAndStamps() throws {
        let test = try makeTestDatabase()
        let root = try tempDirectory()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())

        // Ten older backups on disk.
        let backups = try backupsDirectory(at: root)
        for index in 1 ... maxBackupsKept {
            let name = "backup_2026-09-\(index < 10 ? "0\(index)" : "\(index)")T00-00-00-000Z\(backupExtension)"
            try Data("old".utf8).write(to: backups.appendingPathComponent(name))
        }

        let url = try writeBackup(
            repos: test.repos,
            documentDirectory: root,
            appVersion: "1.0.0",
            now: fixtureExportTime
        )
        #expect(url.lastPathComponent == "backup_2026-10-19T12-00-00-000Z\(backupExtension)")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let remaining = try listBackups(at: root)
        #expect(remaining.count == maxBackupsKept)
        #expect(remaining.first?.name == url.lastPathComponent, "the new backup is the newest")
        #expect(!remaining.contains { $0.name.contains("2026-09-01") }, "the oldest rotated out")

        let stamped = try test.repos.settings.getJSON(key: settingsKeyLastBackupAt, as: String.self)
        #expect(stamped == fixtureExportTime)
    }

    @Test("background trigger is throttled hourly, session close is not (US-15.1)")
    func backgroundTriggerThrottles() throws {
        let test = try makeTestDatabase()
        let root = try tempDirectory()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())

        // Fresh install: background trigger writes.
        #expect(try maybeWriteAutomaticBackup(
            repos: test.repos,
            documentDirectory: root,
            trigger: .appBackground,
            now: fixtureExportTime
        ) == true)

        // Within the hour the background trigger is throttled.
        #expect(try maybeWriteAutomaticBackup(
            repos: test.repos,
            documentDirectory: root,
            trigger: .appBackground,
            now: "2026-10-19T12:30:00.000Z"
        ) == false)

        // Session close always backs up.
        #expect(try maybeWriteAutomaticBackup(
            repos: test.repos,
            documentDirectory: root,
            trigger: .sessionClose,
            now: "2026-10-19T12:30:00.000Z"
        ) == true)

        // Past the hour the background trigger writes again.
        #expect(try maybeWriteAutomaticBackup(
            repos: test.repos,
            documentDirectory: root,
            trigger: .appBackground,
            now: "2026-10-19T14:00:00.000Z"
        ) == true)
        #expect(try listBackups(at: root).count == 3)
    }

    @Test("runScheduledBackup is the throttled background entry point")
    func runScheduledBackupEntry() throws {
        let test = try makeTestDatabase()
        let root = try tempDirectory()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())

        #expect(try runScheduledBackup(repos: test.repos, documentDirectory: root, now: fixtureExportTime) == true)
        #expect(try runScheduledBackup(
            repos: test.repos,
            documentDirectory: root,
            now: "2026-10-19T12:10:00.000Z"
        ) == false)
    }

    @Test("restore applies the archive, snapshots the database, and reports media (US-15.3)")
    func restoreReplacesData() throws {
        let test = try makeTestDatabase()
        let root = try tempDirectory()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())

        // Media file exists at export time.
        let photoURL = root.appendingPathComponent("photos/photo-1.jpg")
        try FileManager.default.createDirectory(at: photoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01, 0x02]).write(to: photoURL)

        let backupURL = try writeBackup(repos: test.repos, documentDirectory: root, appVersion: "1.0.0", now: fixtureExportTime)
        let backupBytes = try Data(contentsOf: backupURL)

        // Diverge from the backup: rename the gym.
        _ = try test.repos.gyms.rename(id: "gym-1", name: "Changed Name")

        // Simulated database file for the pre-import snapshot.
        let dbFile = try tempDirectory().appendingPathComponent("cybersend.sqlite")
        try Data("fake".utf8).write(to: dbFile)

        let report = try restoreBackup(
            writer: test.writer,
            repos: test.repos,
            documentDirectory: root,
            archiveBytes: backupBytes,
            databasePath: dbFile.path,
            now: "2026-10-19T15:00:00.000Z"
        )
        #expect(report.schemaVersion == currentSchemaVersion)
        #expect(report.migratedFrom == nil)
        #expect(report.warnings.isEmpty)
        #expect(report.media.verified == 1)
        #expect(report.media.restored == 0)

        // The gym name is back to the backed up value.
        let gym = try test.repos.gyms.get(id: "gym-1")
        #expect(gym?.name == "Boulder Garden")

        // The pre-import snapshot landed in backups/ next to the archives.
        let snapshotName = "pre_import_2026-10-19T15-00-00-000Z.sqlite"
        #expect(FileManager.default.fileExists(atPath: try backupsDirectory(at: root).appendingPathComponent(snapshotName).path))
    }

    @Test("restore rewrites missing media from the archive and hashes every file")
    func restoreReconcilesMedia() throws {
        let test = try makeTestDatabase()
        let root = try tempDirectory()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())

        let photoURL = root.appendingPathComponent("photos/photo-1.jpg")
        try FileManager.default.createDirectory(at: photoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x0A, 0x0B]).write(to: photoURL)
        let backupURL = try writeBackup(repos: test.repos, documentDirectory: root, appVersion: "1.0.0", now: fixtureExportTime)
        let backupBytes = try Data(contentsOf: backupURL)

        // The photo is gone (retention sweep) and another one diverged.
        try FileManager.default.removeItem(at: photoURL)
        let divergedURL = root.appendingPathComponent("photos/other.jpg")
        try Data("other".utf8).write(to: divergedURL)

        let report = try restoreBackup(
            writer: test.writer,
            repos: test.repos,
            documentDirectory: root,
            archiveBytes: backupBytes,
            now: "2026-10-19T15:00:00.000Z"
        )
        #expect(report.media.restored == 1)
        #expect(FileManager.default.fileExists(atPath: photoURL.path))
        #expect(try Data(contentsOf: photoURL) == Data([0x0A, 0x0B]))
    }

    @Test("a diverged file is overwritten by the archive copy, an unverifiable one is skipped")
    func restoreOverwritesDivergedMedia() throws {
        let root = try tempDirectory()
        let photoURL = root.appendingPathComponent("photos/photo-1.jpg")
        try FileManager.default.createDirectory(at: photoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: photoURL)

        let goodBytes = Data([0x01, 0x02, 0x03])
        let manifest = BackupManifest(
            app: "cybersend",
            appVersion: "1.0.0",
            schemaVersion: currentSchemaVersion,
            createdAt: fixtureExportTime,
            media: [
                BackupManifestMediaEntry(path: "photos/photo-1.jpg", sha256: sha256Hex(goodBytes)),
                BackupManifestMediaEntry(path: "photos/gone.jpg", sha256: sha256Hex(Data([0x09]))),
            ]
        )
        let bytes = try packBackup(BackupArchive(
            manifest: manifest,
            data: "{}",
            media: ["photos/photo-1.jpg": goodBytes]
        ))
        let archive = try unpackBackup(bytes)
        let result = reconcileMedia(manifestEntries: archive.manifest.media, archiveMedia: archive.media, at: root)

        #expect(result.report.restored == 1, "the diverged photo is rewritten from the archive")
        #expect(result.report.skipped == 1, "the photo missing from the archive is skipped")
        #expect(result.warnings.contains { $0.contains("photos/gone.jpg") })
        #expect(try Data(contentsOf: photoURL) == goodBytes)
    }

    @Test("corrupt archives restore nothing (US-16.3)")
    func corruptArchiveRestoresNothing() throws {
        let test = try makeTestDatabase()
        let root = try tempDirectory()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())
        let before = try test.repos.dump.dumpAll()

        #expect(throws: BackupArchiveError.self) {
            try restoreBackup(
                writer: test.writer,
                repos: test.repos,
                documentDirectory: root,
                archiveBytes: Data([0x00, 0x01])
            )
        }
        #expect(try test.repos.dump.dumpAll() == before)
    }

    @Test("backing up 1000 sessions plus 5000 attempts stays inside the 5 s budget (US-15.4)")
    func backupPerformanceBudget() throws {
        let test = try makeTestDatabase()
        let root = try tempDirectory()

        var gyms: [ExportRow] = [exportRow(.gyms, [
            "id": .text("gym-perf"),
            "name": .text("Perf Gym"),
            "is_archived": .integer(0),
            "created_at": .text(fixtureSeedTime),
            "updated_at": .text(fixtureSeedTime),
        ])]
        var climbs: [ExportRow] = []
        for index in 0 ..< 50 {
            climbs.append(exportRow(.climbs, [
                "id": .text("climb-\(index)"),
                "gym_id": .text("gym-perf"),
                "grade_system_id": .text("v_scale"),
                "grade_level_id": .text("v\(index % 18)"),
                "is_active": .integer(1),
                "is_archived": .integer(0),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ]))
        }
        var sessions: [ExportRow] = []
        for index in 0 ..< 1000 {
            sessions.append(exportRow(.sessions, [
                "id": .text("session-\(index)"),
                "gym_id": .text("gym-perf"),
                "started_at": .text(fixtureSeedTime),
                "rpe": .integer(5),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ]))
        }
        var attempts: [ExportRow] = []
        for index in 0 ..< 5000 {
            attempts.append(exportRow(.attempts, [
                "id": .text("attempt-\(index)"),
                "session_id": .text("session-\(index / 5)"),
                "climb_id": .text("climb-\(index % 50)"),
                "attempt_no": .integer(1),
                "outcome": .text("project"),
                "attempted_at": .text(fixtureSeedTime),
            ]))
        }
        try seedDatabase(test.writer, repos: test.repos, rows: [
            .gyms: gyms,
            .climbs: climbs,
            .sessions: sessions,
            .attempts: attempts,
        ])

        let clock = ContinuousClock()
        let start = clock.now
        let bytes = try buildBackupBytes(
            repos: test.repos,
            documentRoot: root,
            appVersion: "1.0.0",
            now: fixtureExportTime
        )
        let elapsed = start.duration(to: clock.now)
        #expect(!bytes.isEmpty)
        #expect(elapsed < .seconds(5), "US-15.4 budget: took \(elapsed)")
    }
}

/// A fresh temporary directory per call, cleaned up when the test process exits.
private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cybersend_tests_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
