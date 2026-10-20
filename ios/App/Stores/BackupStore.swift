import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import Foundation

// Settings data store (M2 Task 5, US-14 to US-16): export files for the share sheet, the
// on demand backup, the confirmation gated restore and import entry points, and the last
// backup stamp. The restore and import operations go through the BackupProcedures the
// bootstrap bound to the live database writer, so app sources never import GRDB. Views
// call this store only; repositories never appear on a screen (US-13).

@MainActor
final class BackupStore: ObservableObject {
    /// Newest backup first. Empty when no local backup exists yet.
    @Published private(set) var backupCount: Int = 0
    /// ISO 8601 stamp of the last automatic or manual backup (settings key
    /// settingsKeyLastBackupAt); nil before the first backup.
    @Published private(set) var lastBackupAt: String?
    /// Ready to share JSON export (US-14.1).
    @Published private(set) var exportJSONURL: URL?
    /// Ready to share CSV exports per entity (US-14.2).
    @Published private(set) var exportCSVURLs: [CsvEntity: URL] = [:]
    @Published private(set) var lastErrorMessage: String?

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
        refresh()
        prepareExports()
    }

    /// Reloads the last backup stamp and the local backup count (listBackups).
    func refresh() {
        do {
            let backups = try listBackups(at: services.documentDirectory)
            backupCount = backups.count
            lastBackupAt = try? services.repos.settings.getJSON(key: settingsKeyLastBackupAt, as: String.self)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Could not list local backups: \(error.localizedDescription)"
        }
    }

    /// Writes one backup now (US-15). Failures surface as a warning, never a block.
    func backupNow() throws {
        do {
            _ = try writeBackup(repos: services.repos, documentDirectory: services.documentDirectory)
            refresh()
        } catch {
            lastErrorMessage = "Backup failed: \(error.localizedDescription)"
            throw error
        }
    }

    /// Restores the newest local backup (US-15.3). The settings screen may only call this
    /// from the destructive confirmation dialog (docs/reviews.md M1 review obligation);
    /// RestoreGateTests and the settings restore smoke prove the gate.
    func restoreNewestBackup() throws -> ImportReport {
        let backups = try listBackups(at: services.documentDirectory)
        guard let newest = backups.first else {
            throw BackupStoreError.noLocalBackups
        }
        let bytes = try Data(contentsOf: newest.url)
        let report = try services.backupProcedures.restoreArchive(bytes)
        refresh()
        prepareExports()
        return report
    }

    /// Imports one picked file: a .cybersend archive restores like a backup, anything
    /// else imports as a full JSON export payload (US-16). Same confirmation obligation
    /// as restoreNewestBackup.
    func importFile(at url: URL) throws -> ImportReport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let report: ImportReport
        let isArchive = backupExtension == ".\(url.pathExtension.lowercased())"
        if isArchive {
            report = try services.backupProcedures.restoreArchive(try Data(contentsOf: url))
        } else {
            let json = try String(contentsOf: url, encoding: .utf8)
            report = try services.backupProcedures.importPayload(json)
        }
        refresh()
        prepareExports()
        return report
    }

    /// Rebuilds the shareable export files against the current data (US-14). Exports live
    /// in exports/ under the storage root, fully offline (US-14.4).
    func prepareExports() {
        do {
            let now = nowISO8601()
            let slug = timestampSlug(now)
            exportJSONURL = try writeExportFile(
                buildExportJSON(repos: services.repos, now: now),
                named: "cybersend-export-\(slug).json"
            )
            var csvURLs: [CsvEntity: URL] = [:]
            for entity in CsvEntity.allCases {
                csvURLs[entity] = try writeExportFile(
                    buildExportCSV(repos: services.repos, entity: entity),
                    named: "cybersend-\(entity.rawValue)-\(slug).csv"
                )
            }
            exportCSVURLs = csvURLs
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func writeExportFile(_ contents: String, named name: String) throws -> URL {
        let directory = services.documentDirectory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Plain-language errors from the settings data store.
struct BackupStoreError: LocalizedError {
    let message: String

    static let noLocalBackups = BackupStoreError(
        "No local backups yet. Tap Back up now to write one."
    )

    private init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

extension BackupStore {
    /// The settings row label for the last backup stamp; nil text when none exists yet.
    var lastBackupLabel: String {
        guard let lastBackupAt else { return "No automatic backup yet." }
        return "Last backup: \(DisplayDate.string(from: lastBackupAt))"
    }
}
