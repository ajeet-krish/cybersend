import CryptoKit
import CyberSendData
import CyberSendDomain
import Foundation

// Device side export: full backup bytes and JSON/CSV text built from the repositories
// (port of src/features/backup/export_service.ts). The share sheet and the on device
// directories are M2 UI work; this layer writes to caller supplied directories and
// returns file URLs. Works fully offline (US-14.4).

public struct BuildBackupOptions: Equatable, Sendable {
    /// Include videos whose retention_class is not keep (kept videos always travel).
    public let includeVideos: Bool

    public init(includeVideos: Bool = false) {
        self.includeVideos = includeVideos
    }
}

/// The app version string embedded in manifests and export payloads. Falls back to
/// 0.0.0 outside a bundled app (tests and command line tools).
public func currentAppVersion() -> String {
    guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
          !version.isEmpty
    else {
        return "0.0.0"
    }
    return version
}

/// Lowercase hex SHA-256 of some bytes (CryptoKit, per docs/architecture.md).
public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The document backups directory (created when missing).
public func backupsDirectory(at documentDirectory: URL) throws -> URL {
    let directory = documentDirectory.appendingPathComponent("backups", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Full JSON export text: every table plus schema_version (US-14.1).
public func buildExportJSON(repos: Repositories, now: String) throws -> String {
    let dump = try repos.dump.dumpAll()
    let schemaVersion = try repos.dump.schemaVersion()
    return serializeExportPayload(buildExportPayload(
        dump: dump.rows,
        schemaVersion: schemaVersion,
        exportedAt: now
    ))
}

/// CSV export for one entity (US-14.2): sessions, climbs (including archived and
/// inactive), or every attempt of every session, matching the TypeScript service.
public func buildExportCSV(repos: Repositories, entity: CsvEntity) throws -> String {
    switch entity {
    case .sessions:
        let sessions = try repos.sessions.list(limit: 100_000).map(\.session)
        return sessionsToCsv(sessions)
    case .climbs:
        let climbs = try repos.climbs.list(options: ListClimbsOptions(
            includeArchived: true,
            includeInactive: true
        ))
        return climbsToCsv(climbs)
    case .attempts:
        let sessions = try repos.sessions.list(limit: 100_000).map(\.session)
        var attempts: [Attempt] = []
        for session in sessions {
            attempts.append(contentsOf: try repos.attempts.listBySession(sessionId: session.id))
        }
        return attemptsToCsv(attempts)
    }
}

/// Full backup: manifest.json plus data.json plus media (photos always; videos when
/// marked keep or when the user opts in with includeVideos, per docs/architecture.md
/// and docs/decisions.md), packed into one .cybersend archive (port of
/// build_backup_bytes). The TypeScript service required both the keep flag and the
/// opt in; the approved docs say keep or opt in, so the Swift port follows the docs.
public func buildBackupBytes(
    repos: Repositories,
    documentRoot: URL,
    appVersion: String,
    now: String,
    options: BuildBackupOptions = BuildBackupOptions()
) throws -> Data {
    let dump = try repos.dump.dumpAll()
    let schemaVersion = try repos.dump.schemaVersion()
    let payload = buildExportPayload(dump: dump.rows, schemaVersion: schemaVersion, exportedAt: now)

    var media: [String: Data] = [:]
    var mediaEntries: [BackupManifestMediaEntry] = []
    for photo in dump[.photos] {
        guard case .text(let uri) = photo["uri"] ?? .null, !uri.isEmpty else { continue }
        guard let bytes = readMediaBytes(relativeURI: uri, at: documentRoot) else { continue }
        media[uri] = bytes
        mediaEntries.append(BackupManifestMediaEntry(path: uri, sha256: sha256Hex(bytes)))
    }
    let keptOrOptedInVideo: (ExportRow) -> Bool = { video in
        if case .text(let retention) = video["retention_class"] ?? .null, retention == "keep" {
            return true
        }
        return options.includeVideos
    }
    for video in dump[.videos] where keptOrOptedInVideo(video) {
        guard case .text(let uri) = video["uri"] ?? .null, !uri.isEmpty else { continue }
        guard let bytes = readMediaBytes(relativeURI: uri, at: documentRoot) else { continue }
        media[uri] = bytes
        mediaEntries.append(BackupManifestMediaEntry(path: uri, sha256: sha256Hex(bytes)))
    }

    let manifest = BackupManifest(
        app: exportAppID,
        appVersion: appVersion,
        schemaVersion: schemaVersion,
        createdAt: now,
        media: mediaEntries
    )
    return try packBackup(BackupArchive(
        manifest: manifest,
        data: serializeExportPayload(payload),
        media: media
    ))
}

/// Reads a media file stored relative to the document root. Returns nil when the file
/// is gone (for example, a retention sweep already deleted a video).
private func readMediaBytes(relativeURI: String, at documentRoot: URL) -> Data? {
    let url = documentRoot.appendingPathComponent(relativeURI)
    return try? Data(contentsOf: url)
}

/// Replaces the ":" and "." of an ISO timestamp with "-" for file names (port of
/// timestamp_slug).
public func timestampSlug(_ iso: String) -> String {
    iso.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
}
