import CyberSendDomain
import Foundation
import ZIPFoundation

// .cybersend backup archive (port of src/features/backup/zip.ts): a zip of
// manifest.json, data.json, and optional media files, produced with ZIPFoundation
// (docs/decisions.md: backup as a .cybersend zip with staging import).

public let backupExtension = ".cybersend"

public struct BackupManifestMediaEntry: Equatable, Sendable {
    public let path: String
    public let sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

public struct BackupManifest: Equatable, Sendable {
    public let app: String
    public let appVersion: String
    public let schemaVersion: Int
    public let createdAt: String
    public let media: [BackupManifestMediaEntry]

    public init(app: String, appVersion: String, schemaVersion: Int, createdAt: String, media: [BackupManifestMediaEntry]) {
        self.app = app
        self.appVersion = appVersion
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.media = media
    }
}

public struct BackupArchive: Equatable, Sendable {
    public let manifest: BackupManifest
    public let data: String
    /// Media bytes keyed by the document relative path (photos/photo.jpg and so on).
    public let media: [String: Data]

    public init(manifest: BackupManifest, data: String, media: [String: Data]) {
        self.manifest = manifest
        self.data = data
        self.media = media
    }
}

public struct BackupArchiveError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

extension BackupArchiveError: LocalizedError {
    public var errorDescription: String? { message }
}

private let archiveOpenFailedMessage = "The backup file could not be opened. Nothing was restored."
private let archiveMissingEntriesMessage =
    "The backup archive is missing manifest.json or data.json. Nothing was restored."
private let manifestNotJSONMessage = "The backup manifest is not valid JSON. Nothing was restored."
private let manifestNotCyberSendMessage = "The backup manifest is not a CyberSend manifest. Nothing was restored."

/// Serializes a manifest with JSON.stringify(manifest, null, 2) key order: app,
/// app_version, schema_version, created_at, media; entries as path then sha256.
public func serializeManifest(_ manifest: BackupManifest) -> String {
    let mediaEntries = manifest.media.map { entry in
        JSONNode.object([
            ("path", .string(entry.path)),
            ("sha256", .string(entry.sha256)),
        ])
    }
    let root = JSONNode.object([
        ("app", .string(manifest.app)),
        ("app_version", .string(manifest.appVersion)),
        ("schema_version", .number(String(manifest.schemaVersion))),
        ("created_at", .string(manifest.createdAt)),
        ("media", .array(mediaEntries)),
    ])
    return JSONRenderer.render(root)
}

/// Packs manifest.json, data.json, and media files into one .cybersend zip (port of
/// pack_backup).
public func packBackup(_ archive: BackupArchive) throws -> Data {
    let fileManager = FileManager.default
    let temporaryURL = fileManager.temporaryDirectory
        .appendingPathComponent("cybersend_pack_\(UUID().uuidString).zip")
    defer { try? fileManager.removeItem(at: temporaryURL) }

    guard let zip = try Archive(url: temporaryURL, accessMode: .create) else {
        throw BackupArchiveError(archiveOpenFailedMessage)
    }

    let manifestData = Data(serializeManifest(archive.manifest).utf8)
    try addFileEntry(to: zip, path: "manifest.json", data: manifestData)
    try addFileEntry(to: zip, path: "data.json", data: Data(archive.data.utf8))
    for (path, bytes) in archive.media.sorted(by: { $0.key < $1.key }) {
        try addFileEntry(to: zip, path: "media/\(path)", data: bytes)
    }

    return try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
}

private func addFileEntry(to zip: Archive, path: String, data: Data) throws {
    try zip.addEntry(
        with: path,
        type: .file,
        uncompressedSize: Int64(data.count),
        compressionMethod: .deflate
    ) { position, size in
        let start = Int(position)
        return data.subdata(in: start ..< start + size)
    }
}

/// Reads a .cybersend archive back into manifest, data, and media (port of
/// unpack_backup). Every failure is a plain-language BackupArchiveError with zero
/// restore side effects.
public func unpackBackup(_ bytes: Data) throws -> BackupArchive {
    let fileManager = FileManager.default
    let temporaryURL = fileManager.temporaryDirectory
        .appendingPathComponent("cybersend_unpack_\(UUID().uuidString).zip")
    defer { try? fileManager.removeItem(at: temporaryURL) }
    do {
        try bytes.write(to: temporaryURL)
    } catch {
        throw BackupArchiveError(archiveOpenFailedMessage)
    }
    guard let zip = try? Archive(url: temporaryURL, accessMode: .read) else {
        throw BackupArchiveError(archiveOpenFailedMessage)
    }

    var manifestBytes: Data?
    var dataBytes: Data?
    var media: [String: Data] = [:]
    let mediaPrefix = "media/"
    for entry in zip {
        let contents = try extractEntry(entry, from: zip)
        switch entry.path {
        case "manifest.json":
            manifestBytes = contents
        case "data.json":
            dataBytes = contents
        default:
            if entry.path.hasPrefix(mediaPrefix), entry.path.count > mediaPrefix.count {
                media[String(entry.path.dropFirst(mediaPrefix.count))] = contents
            }
        }
    }

    guard let manifestData = manifestBytes, let data = dataBytes else {
        throw BackupArchiveError(archiveMissingEntriesMessage)
    }
    guard let manifestText = String(data: manifestData, encoding: .utf8),
          let dataText = String(data: data, encoding: .utf8)
    else {
        throw BackupArchiveError(manifestNotJSONMessage)
    }

    let manifest = try parseManifest(manifestText)
    return BackupArchive(manifest: manifest, data: dataText, media: media)
}

private func extractEntry(_ entry: Entry, from zip: Archive) throws -> Data {
    var contents = Data()
    do {
        _ = try zip.extract(entry) { chunk in
            contents.append(chunk)
        }
    } catch {
        throw BackupArchiveError(archiveOpenFailedMessage)
    }
    return contents
}

/// Validates the manifest shape (port of is_manifest, plus per entry type checks so the
/// typed manifest cannot smuggle malformed media entries).
private func parseManifest(_ text: String) throws -> BackupManifest {
    guard let data = text.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data),
          let object = raw as? [String: Any],
          object["app"] as? String == exportAppID,
          let appVersion = object["app_version"] as? String,
          let schemaVersion = jsonInteger(object["schema_version"]),
          let createdAt = object["created_at"] as? String,
          let rawMedia = object["media"] as? [Any]
    else {
        if (try? JSONSerialization.jsonObject(with: Data(text.utf8))) == nil {
            throw BackupArchiveError(manifestNotJSONMessage)
        }
        throw BackupArchiveError(manifestNotCyberSendMessage)
    }
    var media: [BackupManifestMediaEntry] = []
    for entry in rawMedia {
        guard let entryObject = entry as? [String: Any],
              let path = entryObject["path"] as? String,
              let sha256 = entryObject["sha256"] as? String
        else {
            throw BackupArchiveError(manifestNotCyberSendMessage)
        }
        media.append(BackupManifestMediaEntry(path: path, sha256: sha256))
    }
    return BackupManifest(
        app: exportAppID,
        appVersion: appVersion,
        schemaVersion: schemaVersion,
        createdAt: createdAt,
        media: media
    )
}
