import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import XCTest
@testable import CyberSend

// M3 photo UI wiring smoke (docs/architecture.md M3 app layer): the media sweep
// reconciles rows against files, the Development only synthetic capture feeds the real
// ingest pipeline byte for byte like camera and library photos, and the camera seam
// refuses to present without hardware or permission (the simulator exercises the
// degraded path for real). The PhotoStore level behavior (add, replace, delete,
// retention) stays covered by the package suite.

@MainActor
final class PhotoMediaWiringTests: XCTestCase {
    func testSweepRemovesOrphanRowsAndOrphanFiles() throws {
        let root = try makeTemporaryRoot(label: "sweep-reconcile")
        defer { removeTemporaryRoot(root) }

        let environment = try XCTUnwrap(
            AppBootstrap(documentDirectory: root, variant: .development).run().environment
        )
        let repos = environment.repos
        let storage = environment.media.storage

        // A live photo: row plus working copy and thumb on disk.
        let liveID = UUID().uuidString
        let liveWorking = try storage.writeWorking(Data([0x01]), photoID: liveID)
        let liveThumb = try storage.writeThumb(Data([0x02]), photoID: liveID)
        _ = try repos.media.createPhoto(CreatePhotoInput(
            id: liveID, uri: liveWorking, width: 10, height: 10, thumbUri: liveThumb
        ))

        // A dead photo: row whose working copy was lost, leaving an orphaned thumb.
        let deadID = UUID().uuidString
        let deadWorking = try storage.writeWorking(Data([0x03]), photoID: deadID)
        let deadThumb = try storage.writeThumb(Data([0x04]), photoID: deadID)
        _ = try repos.media.createPhoto(CreatePhotoInput(
            id: deadID, uri: deadWorking, width: 10, height: 10, thumbUri: deadThumb
        ))
        try storage.delete(relativeURI: deadWorking)

        // An orphan file nothing references (interrupted write).
        let orphanID = UUID().uuidString
        try storage.writeOriginal(Data([0x05]), photoID: orphanID, fileExtension: "jpg")

        let report = try environment.media.runSweep()

        XCTAssertEqual(report.deletedRows, 1, "the row without a working copy is dead")
        XCTAssertEqual(report.deletedFiles, 2, "the dead row's thumb and the orphan original are removed")
        XCTAssertEqual(try repos.media.listAllPhotos().map(\.id), [liveID])
        XCTAssertTrue(storage.fileExists(relativeURI: liveWorking))
        XCTAssertTrue(storage.fileExists(relativeURI: liveThumb))
        XCTAssertEqual(try storage.listPhotoFileRelativeURIs(), [liveWorking, liveThumb].sorted())
    }

    func testSyntheticPhotoFeedsTheRealIngestPipeline() throws {
        #if DEVELOPMENT
        let root = try makeTemporaryRoot(label: "synthetic-ingest")
        defer { removeTemporaryRoot(root) }
        let storage = MediaStorage(root: root)

        // The Development only generator is deterministic: two runs are identical bytes.
        guard let bytes = SyntheticPhotoSource.wallJPEG() else {
            XCTFail("the synthetic wall JPEG must encode")
            return
        }
        XCTAssertEqual(SyntheticPhotoSource.wallJPEG(), bytes, "the generator is deterministic")

        let photoID = UUID().uuidString
        let result = try ingestPhoto(PhotoIngestRequest(
            photoID: photoID,
            bytes: bytes,
            source: .library,
            capturedAt: nowISO8601(),
            retention: .keepOriginals
        ), into: storage)

        // The identical pipeline produces the same artifacts as a camera or library
        // photo: 2048 px working copy, 256 px thumb, and the retained original.
        XCTAssertEqual(result.width, SyntheticPhotoSource.width)
        XCTAssertEqual(result.height, SyntheticPhotoSource.height)
        XCTAssertEqual(result.workingUri, "photos/working/\(photoID).jpg")
        XCTAssertEqual(result.thumbUri, "photos/thumbs/\(photoID).jpg")
        XCTAssertNotNil(result.originalUri, "keep originals retains the source bytes")
        XCTAssertTrue(storage.fileExists(relativeURI: result.workingUri))
        XCTAssertTrue(storage.fileExists(relativeURI: result.thumbUri))
        #else
        throw XCTSkip("the synthetic source is compiled out of Internal and Release")
        #endif
    }

    func testCameraSeamRefusesToPresentWithoutHardwareOrPermission() {
        let camera = SystemCameraCapture()
        camera.present()

        let canPresent = camera.isAvailable
            && camera.authorization != .denied
            && camera.authorization != .restricted
        XCTAssertEqual(
            camera.isPresenting,
            canPresent,
            "present starts capture only with hardware and permission; everything else degrades"
        )
        if camera.isPresenting {
            camera.dismiss()
            XCTAssertFalse(camera.isPresenting, "dismiss ends capture and re reads authorization")
        }
    }
}
