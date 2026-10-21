import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Media sweep tests (M3, launch path): orphan rows (working copy gone), orphan files
// (no referencing row), and the idempotence the async after first frame call depends on.

@Suite("MediaSweep")
struct MediaSweepTests {
    @Test("rows with a missing working copy are deleted and their files go too")
    func orphanRowsSwept() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let live = try seedPhotoWithFiles(repos: test.repos, storage: storage, climbId: climbId)
        // The victim lost its working copy (interrupted delete or external removal).
        let victim = try seedPhotoWithFiles(repos: test.repos, storage: storage)
        try storage.delete(relativeURI: victim.uri)

        let report = try sweep(repos: test.repos, storage: storage)

        #expect(report.deletedRows == 1)
        // The victim's thumb and original are now orphans and go in the same pass.
        #expect(report.deletedFiles == 2)
        #expect(try test.repos.media.listAllPhotos().map(\.id) == [live.id])
        #expect(storage.fileExists(relativeURI: live.uri))
        #expect(storage.fileExists(relativeURI: try #require(live.thumbUri)))
        #expect(storage.fileExists(relativeURI: try #require(live.originalUri)))
        #expect(!storage.fileExists(relativeURI: try #require(victim.thumbUri)))
        #expect(!storage.fileExists(relativeURI: try #require(victim.originalUri)))
    }

    @Test("files with no referencing row are deleted while referenced files stay")
    func orphanFilesSwept() throws {
        let test = try makeTestDatabase()
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let kept = try seedPhotoWithFiles(repos: test.repos, storage: storage)

        // Three strays: a working copy, a thumb, and an original with no rows.
        _ = try storage.writeWorking(Data([0x0A]), photoID: UUID().uuidString.lowercased())
        _ = try storage.writeThumb(Data([0x0B]), photoID: UUID().uuidString.lowercased())
        _ = try storage.writeOriginal(Data([0x0C]), photoID: UUID().uuidString.lowercased(), fileExtension: "png")

        let report = try sweep(repos: test.repos, storage: storage)

        #expect(report.deletedRows == 0)
        #expect(report.deletedFiles == 3)
        #expect(try storage.listPhotoFileRelativeURIs() == [kept.uri, try #require(kept.thumbUri),
                                                            try #require(kept.originalUri)].sorted())
    }

    @Test("an already clean install sweeps to zero and stays put")
    func idempotent() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let photo = try seedPhotoWithFiles(repos: test.repos, storage: storage, climbId: climbId)
        // One of each mess: an orphan row with files and a stray file.
        let victim = try seedPhotoWithFiles(repos: test.repos, storage: storage)
        try storage.delete(relativeURI: victim.uri)
        _ = try storage.writeThumb(Data([0x0D]), photoID: UUID().uuidString.lowercased())

        let first = try sweep(repos: test.repos, storage: storage)
        #expect(first.deletedRows == 1)
        #expect(first.deletedFiles == 3, "victim thumb and original plus the stray thumb")

        let second = try sweep(repos: test.repos, storage: storage)
        #expect(second == MediaSweepReport())
        let third = try sweep(repos: test.repos, storage: storage)
        #expect(third == MediaSweepReport())

        #expect(try test.repos.media.listAllPhotos().map(\.id) == [photo.id])
        #expect(try storage.listPhotoFileRelativeURIs().count == 3)
    }

    @Test("a photo without a thumb or original sweeps cleanly")
    func minimalPhotoSweeps() throws {
        let test = try makeTestDatabase()
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let photo = try seedPhotoWithFiles(repos: test.repos, storage: storage, withOriginal: false)

        let report = try sweep(repos: test.repos, storage: storage)

        #expect(report == MediaSweepReport())
        #expect(try test.repos.media.listAllPhotos().map(\.id) == [photo.id])
        #expect(try storage.listPhotoFileRelativeURIs().count == 2)
    }
}
