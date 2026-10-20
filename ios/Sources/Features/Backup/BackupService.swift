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

/// An injected backup clock that is not an ISO 8601 timestamp. The throttle fails
/// explicitly on a caller bug instead of silently falling back to the wall clock
/// Date() (M1 review, throttle clock parsing).
public struct BackupClockError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

extension BackupClockError: LocalizedError {
    public var errorDescription: String? { message }
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
    try bytes.write(to: fileURL, options: .atomic)

    let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in backupsToDelete(names: existing.filter { $0.hasSuffix(backupExtension) }) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    try repos.settings.set(key: settingsKeyLastBackupAt, valueJson: jsonString(now))
    return fileURL
}

/// Returns true when a backup was written, false when a background trigger was
/// throttled (port of maybe_write_automatic_backup). The injected now must be an ISO
/// 8601 timestamp in either shape (with or without fractional seconds); an
/// unparseable one throws BackupClockError instead of silently falling back to the
/// wall clock Date(). The default path still stamps the wall clock through
/// nowISO8601().
public func maybeWriteAutomaticBackup(
    repos: Repositories,
    documentDirectory: URL,
    trigger: BackupTrigger,
    appVersion: String = currentAppVersion(),
    now: String = nowISO8601()
) throws -> Bool {
    let nowDate = try backupClockDate(now)
    if trigger == .appBackground,
       let last = lastAutomaticBackupDate(repos: repos),
       nowDate.timeIntervalSince(last) < automaticBackupIntervalSeconds {
        return false
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
/// getJson null behavior). Both ISO 8601 shapes parse, so a stored stamp without
/// milliseconds still throttles instead of silently disabling the throttle.
private func lastAutomaticBackupDate(repos: Repositories) -> Date? {
    guard let raw = try? repos.settings.get(key: settingsKeyLastBackupAt),
          let data = raw.data(using: .utf8),
          let iso = try? JSONDecoder().decode(String.self, from: data)
    else {
        return nil
    }
    return parseISO8601Tolerant(iso)
}

/// Parses an injected backup clock. Accepts both ISO 8601 shapes, with and without
/// fractional seconds (the TypeScript Date.parse leniency the M1 review asked for);
/// anything else throws instead of falling back to Date(), so a caller bug can never
/// masquerade as a real backup time.
private func backupClockDate(_ iso: String) throws -> Date {
    guard let date = parseISO8601Tolerant(iso) else {
        throw BackupClockError("'\(iso)' is not a valid ISO 8601 time. Nothing was backed up.")
    }
    return date
}

/// Lenient ISO 8601 parse: fractional seconds first (2026-10-19T12:00:00.000Z), then
/// the plain shape (2026-10-19T12:00:00Z). Returns nil when neither shape parses.
func parseISO8601Tolerant(_ iso: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: iso) {
        return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: iso)
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
