import CyberSendData
import CyberSendDomain
import Foundation
import GRDB

// Automatic rotating backups and restore (port of src/features/backup/backup_service.ts,
// US-15 and US-16). A backup is a .cybersend archive written to the document backups
// directory; the newest 10 are kept (requirements US-15.2 wins over the older "last 3"
// wording in docs/decisions.md; see the M1 decision note there). Automatic triggers:
// session close (always) and app background (at most hourly, throttled through the
// settings table).
//
// Integration points for M2: the SwiftUI layer calls runScheduledBackup() from the app
// background lifecycle hook and maybeWriteAutomaticBackup(trigger: .sessionClose) when a
// session closes. Restore is atomic behind this API and the M2 settings screen is the
// confirmation seam: present the user's confirmation, then call restoreBackup.

/// Requirements US-15.2: keep the last 10 backups.
public let maxBackupsKept = 10

/// Requirements US-15.1: at most one automatic backup per hour.
public let automaticBackupIntervalSeconds: TimeInterval = 60 * 60

public enum BackupTrigger: String, Sendable {
    case sessionClose = "session_close"
    case appBackground = "app_background"
}

public struct BackupFile: Equatable, Sendable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// Pure rotation helper (port of backups_to_delete): backup names embed an ISO
/// timestamp, so lexicographic order is chronological. Returns the names to delete,
/// keeping the newest `keep`.
public func backupsToDelete(names: [String], keep: Int = maxBackupsKept) -> [String] {
    Array(names.sorted().reversed().dropFirst(keep))
}

/// The backup files in the document backups directory, newest first.
public func listBackups(at documentDirectory: URL) throws -> [BackupFile] {
    let directory = try backupsDirectory(at: documentDirectory)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names
        .filter { $0.hasSuffix(backupExtension) }
        .sorted()
        .reversed()
        .map { BackupFile(name: $0, url: directory.appendingPathComponent($0)) }
}

/// Writes one backup, rotates the directory down to maxBackupsKept, and records the
/// time under the settings key the hourly throttle reads (port of write_backup).
/// Failures propagate so the caller can show the persistent warning badge (storage
/// full edge case, requirements section 8).
public func writeBackup(
    repos: Repositories,
    documentDirectory: URL,
    appVersion: String = currentAppVersion(),
    now: String = nowISO8601(),
    options: BuildBackupOptions = BuildBackupOptions()
) throws -> URL {
    let bytes = try buildBackupBytes(
        repos: repos,
        documentRoot: documentDirectory,
        appVersion: appVersion,
        now: now,
        options: options
    )
    let directory = try backupsDirectory(at: documentDirectory)
    let fileURL = directory.appendingPathComponent("backup_\(timestampSlug(now))\(backupExtension)")
    try bytes.write(to: fileURL)

    let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in backupsToDelete(names: existing.filter { $0.hasSuffix(backupExtension) }) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    try repos.settings.set(key: settingsKeyLastBackupAt, valueJson: jsonString(now))
    return fileURL
}

/// Returns true when a backup was written, false when a background trigger was
/// throttled (port of maybe_write_automatic_backup).
public func maybeWriteAutomaticBackup(
    repos: Repositories,
    documentDirectory: URL,
    trigger: BackupTrigger,
    appVersion: String = currentAppVersion(),
    now: String = nowISO8601()
) throws -> Bool {
    if trigger == .appBackground, let last = lastAutomaticBackupDate(repos: repos) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let nowDate = formatter.date(from: now) ?? Date()
        if nowDate.timeIntervalSince(last) < automaticBackupIntervalSeconds {
            return false
        }
    }
    _ = try writeBackup(
        repos: repos,
        documentDirectory: documentDirectory,
        appVersion: appVersion,
        now: now
    )
    return true
}

/// The scheduled backup entry point for the app background hook (M2 wires it to the
/// lifecycle). Throttled to at most hourly like maybeWriteAutomaticBackup.
public func runScheduledBackup(
    repos: Repositories,
    documentDirectory: URL,
    appVersion: String = currentAppVersion(),
    now: String = nowISO8601()
) throws -> Bool {
    try maybeWriteAutomaticBackup(
        repos: repos,
        documentDirectory: documentDirectory,
        trigger: .appBackground,
        appVersion: appVersion,
        now: now
    )
}

/// Restores a .cybersend archive (port of restore_backup). Atomicity: the import is
/// one transaction over every table plus a rehearsal load against a staging database,
/// and a best effort snapshot of the main database file is taken into backups/ before
/// the import. That satisfies "restore replaces data atomically after confirmation"
/// (US-15.3, US-16.3) without a physical file swap, which cannot be hot swapped under
/// GRDB connections (the same stance the TypeScript service documents).
public func restoreBackup(
    writer: any DatabaseWriter,
    repos: Repositories,
    documentDirectory: URL,
    archiveBytes: Data,
    databasePath: String? = nil,
    now: String = nowISO8601()
) throws -> ImportReport {
    var warnings: [String] = []

    if let databasePath {
        do {
            let databaseURL = URL(fileURLWithPath: databasePath)
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                let directory = try backupsDirectory(at: documentDirectory)
                let snapshot = directory.appendingPathComponent("pre_import_\(timestampSlug(now)).sqlite")
                try FileManager.default.copyItem(at: databaseURL, to: snapshot)
            }
        } catch {
            warnings.append("Pre-import snapshot failed: \(error.localizedDescription)")
        }
    }

    let archive = try unpackBackup(archiveBytes)
    var report = try importPayloadJSON(archive.data, on: writer)
    let media = reconcileMedia(
        manifestEntries: archive.manifest.media,
        archiveMedia: archive.media,
        at: documentDirectory
    )
    report.media = media.report
    report.warnings.append(contentsOf: warnings)
    report.warnings.append(contentsOf: media.warnings)
    return report
}

/// Reads the last automatic backup timestamp from the settings table. Corrupt values
/// read as nil, so the throttle falls through to writing a backup (the TypeScript
/// getJson null behavior).
private func lastAutomaticBackupDate(repos: Repositories) -> Date? {
    guard let raw = try? repos.settings.get(key: settingsKeyLastBackupAt),
          let data = raw.data(using: .utf8),
          let iso = try? JSONDecoder().decode(String.self, from: data)
    else {
        return nil
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: iso)
}

/// JSON encodes a plain string the way the settings repository stores it.
private func jsonString(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let json = String(data: data, encoding: .utf8)
    else {
        return "\"\(value)\""
    }
    return json
}
