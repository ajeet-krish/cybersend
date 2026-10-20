import Foundation
import Testing
import ZIPFoundation
@testable import CyberSendFeatures

// .cybersend archive pack and unpack (port of src/features/backup/zip.ts): round trip
// plus every plain-language failure with zero restore side effects.

private func sampleArchive(media: [String: Data] = [:]) -> BackupArchive {
    BackupArchive(
        manifest: BackupManifest(
            app: "cybersend",
            appVersion: "1.2.3",
            schemaVersion: 1,
            createdAt: "2026-10-19T12:00:00.000Z",
            media: media.keys.sorted().map { BackupManifestMediaEntry(path: $0, sha256: sha256Hex(media[$0] ?? Data())) }
        ),
        data: "{\"app\": \"cybersend\"}",
        media: media
    )
}

/// Writes a zip with arbitrary entries so the failure paths can be exercised.
private func craftZip(_ entries: [(String, String)]) throws -> Data {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cybersend_craft_\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: url) }
    guard let zip = try Archive(url: url, accessMode: .create) else {
        struct CraftError: Error {}
        throw CraftError()
    }
    for (path, text) in entries {
        let data = Data(text.utf8)
        try zip.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .none
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start ..< start + size)
        }
    }
    return try Data(contentsOf: url)
}

@Suite("Backup archive")
struct BackupArchiveTests {
    @Test("pack then unpack round trips manifest, data, and media")
    func packUnpackRoundTrip() throws {
        let media = ["photos/photo-1.jpg": Data([0xFF, 0xD8, 0xFF, 0x00]), "videos/clip.mp4": Data("mp4".utf8)]
        let bytes = try packBackup(sampleArchive(media: media))
        let unpacked = try unpackBackup(bytes)

        #expect(unpacked.manifest.app == "cybersend")
        #expect(unpacked.manifest.appVersion == "1.2.3")
        #expect(unpacked.manifest.schemaVersion == 1)
        #expect(unpacked.manifest.createdAt == "2026-10-19T12:00:00.000Z")
        #expect(unpacked.manifest.media.map(\.path).sorted() == ["photos/photo-1.jpg", "videos/clip.mp4"])
        #expect(unpacked.data == "{\"app\": \"cybersend\"}")
        #expect(unpacked.media == media)
    }

    @Test("garbage bytes fail with the open message")
    func rejectsGarbage() {
        let error = #expect(throws: BackupArchiveError.self) {
            try unpackBackup(Data([0x00, 0x01, 0x02, 0x03]))
        }
        #expect(error?.message == "The backup file could not be opened. Nothing was restored.")
    }

    @Test("missing manifest or data fails with the missing entries message")
    func rejectsMissingEntries() throws {
        let zipOnlyManifest = try craftZip([("manifest.json", serializeManifest(sampleArchive().manifest))])
        let error = #expect(throws: BackupArchiveError.self) {
            try unpackBackup(zipOnlyManifest)
        }
        #expect(error?.message == "The backup archive is missing manifest.json or data.json. Nothing was restored.")

        let zipOnlyData = try craftZip([("data.json", "{}")])
        #expect(throws: BackupArchiveError.self) {
            try unpackBackup(zipOnlyData)
        }
    }

    @Test("a manifest that is not JSON fails with the manifest message")
    func rejectsManifestNotJSON() throws {
        let zip = try craftZip([("manifest.json", "not json at all"), ("data.json", "{}")])
        let error = #expect(throws: BackupArchiveError.self) {
            try unpackBackup(zip)
        }
        #expect(error?.message == "The backup manifest is not valid JSON. Nothing was restored.")
    }

    @Test("a JSON manifest from another app fails with the CyberSend message")
    func rejectsForeignManifest() throws {
        let zip = try craftZip([
            ("manifest.json", "{\"app\": \"otherapp\", \"app_version\": \"1\", \"schema_version\": 1, \"created_at\": \"x\", \"media\": []}"),
            ("data.json", "{}"),
        ])
        let error = #expect(throws: BackupArchiveError.self) {
            try unpackBackup(zip)
        }
        #expect(error?.message == "The backup manifest is not a CyberSend manifest. Nothing was restored.")
    }

    @Test("media path traversal is rejected at reconciliation")
    func rejectsUnsafeMediaPaths() {
        #expect(isSafeRelativePath("photos/photo-1.jpg"))
        #expect(!isSafeRelativePath("../escape.jpg"))
        #expect(!isSafeRelativePath("photos/../../escape.jpg"))
        #expect(!isSafeRelativePath("/etc/passwd"))
        #expect(!isSafeRelativePath(""))
    }
}
