import Foundation
import Testing
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Media storage tests (M3): the photos tree layout, the delete helpers the sweep and
// stores rely on, and the path safety rules that keep ids and uris from escaping the
// storage root.

@Suite("MediaStorage")
struct MediaStorageTests {
    @Test("writes, reads, and lists under the photos tree")
    func layoutAndReadWrite() throws {
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let id = UUID().uuidString.lowercased()

        let workingUri = try storage.writeWorking(Data([0x01, 0x02]), photoID: id)
        let thumbUri = try storage.writeThumb(Data([0x03]), photoID: id)
        let originalUri = try storage.writeOriginal(Data([0x04, 0x05, 0x06]), photoID: id, fileExtension: "heic")

        #expect(workingUri == "photos/working/\(id).jpg")
        #expect(thumbUri == "photos/thumbs/\(id).jpg")
        #expect(originalUri == "photos/originals/\(id).heic")
        #expect(try storage.read(relativeURI: workingUri) == Data([0x01, 0x02]))
        #expect(storage.fileExists(relativeURI: thumbUri))
        #expect(try storage.listPhotoFileRelativeURIs() == [workingUri, thumbUri, originalUri].sorted())
        // Writes are atomic overwrites: a second write replaces the bytes in place.
        _ = try storage.writeWorking(Data([0x09]), photoID: id)
        #expect(try storage.read(relativeURI: workingUri) == Data([0x09]))
    }

    @Test("video bytes land in the videos tree under a validated id and extension")
    func videoWriteAndRead() throws {
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let id = UUID().uuidString.lowercased()

        let uri = try storage.writeVideo(Data([0x00, 0x01, 0x02]), videoID: id, fileExtension: "MOV")
        #expect(uri == "videos/\(id).mov")
        #expect(try storage.read(relativeURI: uri) == Data([0x00, 0x01, 0x02]))
        #expect(storage.fileExists(relativeURI: uri))

        // Videos never appear in the photo sweep list: the sweep only owns photo files.
        #expect(try storage.listPhotoFileRelativeURIs() == [])

        let extensionEscape = #expect(throws: MediaStorageError.self) {
            try storage.videoRelativeURI(videoID: id, fileExtension: "../escape")
        }
        #expect(extensionEscape != nil)
        let idEscape = #expect(throws: MediaStorageError.self) {
            try storage.videoRelativeURI(videoID: "../escape", fileExtension: "mov")
        }
        #expect(idEscape != nil)

        try storage.delete(relativeURI: uri)
        #expect(!storage.fileExists(relativeURI: uri))
    }

    @Test("reading a missing file returns nil while unsafe uris throw")
    func readMissingAndUnsafe() throws {
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let id = UUID().uuidString.lowercased()
        #expect(try storage.read(relativeURI: "photos/working/\(id).jpg") == nil)

        let traversal = #expect(throws: MediaStorageError.self) {
            try storage.read(relativeURI: "photos/working/../../escape.jpg")
        }
        #expect(traversal != nil)
        let absolute = #expect(throws: MediaStorageError.self) {
            try storage.read(relativeURI: "/etc/passwd")
        }
        #expect(absolute != nil)
        #expect(!storage.fileExists(relativeURI: "../evil"))
    }

    @Test("photo ids must be UUIDs before they become path components")
    func photoIDSafety() throws {
        let storage = MediaStorage(root: try makeTempMediaRoot())

        for hostile in ["../evil", "a/b", "", "..", "not-a-uuid"] {
            let error = #expect(throws: MediaStorageError.self, "id \(hostile)") {
                try storage.workingRelativeURI(photoID: hostile)
            }
            if case .invalidPhotoID? = error {} else {
                Issue.record("expected invalidPhotoID for \(hostile), got \(String(describing: error))")
            }
            #expect(throws: MediaStorageError.self, "thumb id \(hostile)") {
                try storage.thumbRelativeURI(photoID: hostile)
            }
            #expect(throws: MediaStorageError.self, "original id \(hostile)") {
                try storage.originalRelativeURI(photoID: hostile, fileExtension: "jpg")
            }
        }

        // A hostile extension is rejected too.
        let id = UUID().uuidString.lowercased()
        #expect(throws: MediaStorageError.self) {
            try storage.originalRelativeURI(photoID: id, fileExtension: "../sh")
        }
    }

    @Test("deletePhotoFiles removes working, thumb, and original and tolerates gaps")
    func deletePhotoFiles() throws {
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let id = UUID().uuidString.lowercased()
        let workingUri = try storage.writeWorking(Data([0x01]), photoID: id)
        let thumbUri = try storage.writeThumb(Data([0x02]), photoID: id)
        let originalUri = try storage.writeOriginal(Data([0x03]), photoID: id, fileExtension: "jpg")

        let full = Photo(
            id: id, uri: workingUri, thumbUri: thumbUri, originalUri: originalUri,
            width: 10, height: 10, capturedAt: "2026-10-20T00:00:00Z", createdAt: "2026-10-20T00:00:00Z"
        )
        try storage.deletePhotoFiles(photo: full)
        #expect(try storage.listPhotoFileRelativeURIs().isEmpty)

        // A photo whose original was already discarded deletes what exists and moves on.
        let partial = Photo(
            id: id, uri: try storage.writeWorking(Data([0x04]), photoID: id),
            thumbUri: thumbUri, width: 10, height: 10,
            capturedAt: "2026-10-20T00:00:00Z", createdAt: "2026-10-20T00:00:00Z"
        )
        try storage.deletePhotoFiles(photo: partial)
        #expect(try storage.listPhotoFileRelativeURIs().isEmpty)

        // Deleting an already missing relative uri is a no op, not an error.
        try storage.delete(relativeURI: workingUri)
    }

    @Test("listing stays flat: subdirectories are skipped and never recursed")
    func listingIgnoresSubdirectories() throws {
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let id = UUID().uuidString.lowercased()
        let uri = try storage.writeWorking(Data([0x01]), photoID: id)

        try FileManager.default.createDirectory(
            at: storage.workingDirectory.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data([0x02]).write(to: storage.workingDirectory
            .appendingPathComponent("nested")
            .appendingPathComponent("sneaky.jpg"))

        #expect(try storage.listPhotoFileRelativeURIs() == [uri])
    }
}
