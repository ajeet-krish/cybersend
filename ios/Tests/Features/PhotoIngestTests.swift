import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Photo ingest tests (M3, US-17): the 2048 and 256 px pipeline, the EXIF orientation
// bake that makes the working copy the pixels up coordinate source, retention aware
// originals, the tagging save discard path, and the zero partial files guarantee
// (docs/tests.md: synthetic CGImages, orientations 1, 3, 6, 8, and the 8000x6000 memory
// path).

@Suite("PhotoIngest")
struct PhotoIngestTests {
    private func request(
        id: String = UUID().uuidString.lowercased(),
        bytes: Data,
        source: PhotoSource = .camera,
        retention: PhotoRetentionPreference = .keepOriginals
    ) -> PhotoIngestRequest {
        PhotoIngestRequest(
            photoID: id,
            bytes: bytes,
            source: source,
            capturedAt: "2026-10-20T10:00:00Z",
            retention: retention,
            climbId: "climb-1"
        )
    }

    @Test("jpeg ingest writes the 2048 px working copy, the 256 px thumb, and the camera original")
    func jpegIngestKeepOriginals() throws {
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let bytes = try makeQuadrantJPEG(width: 4096, height: 3072)

        let result = try ingestPhoto(request(bytes: bytes), into: storage)

        #expect(result.width == 2048)
        #expect(result.height == 1536)
        #expect(result.workingUri == "photos/working/\(result.photoID).jpg")
        #expect(result.thumbUri == "photos/thumbs/\(result.photoID).jpg")
        #expect(result.originalUri == "photos/originals/\(result.photoID).jpg")
        #expect(result.warnsLargeSource == false)
        #expect(result.source == .camera)
        #expect(result.climbId == "climb-1")

        let workingBytes = try #require(try storage.read(relativeURI: result.workingUri))
        #expect([UInt8](workingBytes.prefix(2)) == [0xFF, 0xD8], "the working copy is a JPEG")
        let working = try decodeStoredImage(at: try storage.url(relativeURI: result.workingUri))
        #expect(working.width == 2048)
        #expect(working.height == 1536)

        let thumb = try decodeStoredImage(at: try storage.url(relativeURI: result.thumbUri))
        #expect(thumb.width == 256)
        #expect(thumb.height == 192)

        let original = try decodeStoredImage(at: try storage.url(relativeURI: try #require(result.originalUri)))
        #expect(original.width == 4096)
        #expect(original.height == 3072)
    }

    @Test("library png bytes travel verbatim as the original with the png extension")
    func libraryPngVerbatim() throws {
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let bytes = try makeQuadrantPNG(width: 120, height: 90)

        let result = try ingestPhoto(request(bytes: bytes, source: .library), into: storage)

        #expect(result.originalUri == "photos/originals/\(result.photoID).png")
        #expect(try storage.read(relativeURI: try #require(result.originalUri)) == bytes)
        // The working copy and thumb are always JPEG regardless of the source container.
        let workingBytes = try #require(try storage.read(relativeURI: result.workingUri))
        #expect([UInt8](workingBytes.prefix(2)) == [0xFF, 0xD8])
        let working = try decodeStoredImage(at: try storage.url(relativeURI: result.workingUri))
        #expect(working.width == 120)
        #expect(working.height == 90)
    }

    @Test("EXIF orientations 1, 3, 6, and 8 bake into pixels up working copies")
    func exifOrientationBake() throws {
        // The stored image is landscape with red, green, blue, yellow in display
        // quadrants; the bake must rotate it so the working copy reads pixels up.
        struct OrientationCase {
            let orientation: Int
            let expectedWidth: Int
            let expectedHeight: Int
            let topLeft: [UInt8]
            let topRight: [UInt8]
            let bottomLeft: [UInt8]
            let bottomRight: [UInt8]
        }
        let cases: [OrientationCase] = [
            // Orientation 1: no rotation.
            OrientationCase(orientation: 1, expectedWidth: 128, expectedHeight: 64,
                             topLeft: quadrantRed, topRight: quadrantGreen,
                             bottomLeft: quadrantBlue, bottomRight: quadrantYellow),
            // Orientation 3: rotate 180 degrees for display.
            OrientationCase(orientation: 3, expectedWidth: 128, expectedHeight: 64,
                             topLeft: quadrantYellow, topRight: quadrantBlue,
                             bottomLeft: quadrantGreen, bottomRight: quadrantRed),
            // Orientation 6: rotate 90 degrees clockwise for display (dimensions swap).
            OrientationCase(orientation: 6, expectedWidth: 64, expectedHeight: 128,
                             topLeft: quadrantBlue, topRight: quadrantRed,
                             bottomLeft: quadrantYellow, bottomRight: quadrantGreen),
            // Orientation 8: rotate 90 degrees counter clockwise for display (swap).
            OrientationCase(orientation: 8, expectedWidth: 64, expectedHeight: 128,
                             topLeft: quadrantGreen, topRight: quadrantYellow,
                             bottomLeft: quadrantRed, bottomRight: quadrantBlue),
        ]
        for testCase in cases {
            let storage = MediaStorage(root: try makeTempMediaRoot())
            let bytes = try makeQuadrantJPEG(width: 128, height: 64, orientation: testCase.orientation)

            let result = try ingestPhoto(request(bytes: bytes, retention: .discardOriginals), into: storage)
            let working = try decodeStoredImage(at: try storage.url(relativeURI: result.workingUri))

            #expect(working.width == testCase.expectedWidth, "orientation \(testCase.orientation) width")
            #expect(working.height == testCase.expectedHeight, "orientation \(testCase.orientation) height")
            let samples = try sampleQuadrants(working)
            #expect(sampleMatches(samples.topLeft, testCase.topLeft), "orientation \(testCase.orientation) top left")
            #expect(sampleMatches(samples.topRight, testCase.topRight), "orientation \(testCase.orientation) top right")
            #expect(sampleMatches(samples.bottomLeft, testCase.bottomLeft), "orientation \(testCase.orientation) bottom left")
            #expect(sampleMatches(samples.bottomRight, testCase.bottomRight), "orientation \(testCase.orientation) bottom right")
        }
    }

    @Test("discard retention skips the original entirely at ingest")
    func discardRetentionSkipsOriginal() throws {
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let bytes = try makeQuadrantJPEG(width: 4096, height: 3072)

        let result = try ingestPhoto(request(bytes: bytes, retention: .discardOriginals), into: storage)

        #expect(result.originalUri == nil)
        #expect(try storage.listPhotoFileRelativeURIs().count == 2, "working and thumb only")
        // The working copy is still the full 2048 policy size.
        #expect(result.width == 2048)
        #expect(result.height == 1536)
    }

    @Test("discardOriginal deletes the original file and clears original_uri (tagging save)")
    func discardOriginalClearsFileAndRow() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let bytes = try makeQuadrantJPEG(width: 640, height: 480)

        let result = try ingestPhoto(request(bytes: bytes), into: storage)
        let photo = try test.repos.media.createPhoto(CreatePhotoInput(
            id: result.photoID,
            uri: result.workingUri,
            width: result.width,
            height: result.height,
            climbId: climbId,
            thumbUri: result.thumbUri,
            originalUri: result.originalUri,
            source: result.source,
            capturedAt: result.capturedAt
        ))
        let originalUri = try #require(photo.originalUri)
        #expect(storage.fileExists(relativeURI: originalUri))

        let updated = try discardOriginal(into: storage, photo: photo, media: test.repos.media)

        #expect(updated.originalUri == nil)
        #expect(!storage.fileExists(relativeURI: originalUri))
        #expect(try test.repos.media.getPhoto(id: photo.id)?.originalUri == nil, "the row lost the uri")
        // Working copy and thumb survive the discard.
        #expect(storage.fileExists(relativeURI: photo.uri))
        #expect(photo.thumbUri.map(storage.fileExists) == true)
    }

    @Test("the 8000x6000 memory path succeeds for both retentions")
    func largeMemoryPath() throws {
        let bytes = try makeQuadrantJPEG(width: 8000, height: 6000)

        // Discard: never touches the full resolution pixels, working copy capped.
        let discardStorage = MediaStorage(root: try makeTempMediaRoot())
        let discarded = try ingestPhoto(request(bytes: bytes, retention: .discardOriginals), into: discardStorage)
        #expect(discarded.width == 2048)
        #expect(discarded.height == 1536)
        #expect(discarded.originalUri == nil)

        // Keep, camera path: the full resolution re-encode rides the autoreleasepool.
        let keepStorage = MediaStorage(root: try makeTempMediaRoot())
        let kept = try ingestPhoto(request(bytes: bytes), into: keepStorage)
        #expect(kept.width == 2048)
        #expect(kept.height == 1536)
        let original = try decodeStoredImage(at: try keepStorage.url(relativeURI: try #require(kept.originalUri)))
        #expect(original.width == 8000)
        #expect(original.height == 6000)
    }

    @Test("sources over 30 MB surface the large source warning")
    func largeSourceWarning() throws {
        let storage = MediaStorage(root: try makeTempMediaRoot())
        // A real decodable JPEG padded past the threshold; ImageIO ignores the trailing
        // bytes after the end of image marker.
        var bytes = try makeQuadrantJPEG(width: 640, height: 480)
        bytes.append(Data(count: photoIngestLargeSourceBytes))
        #expect(bytes.count > photoIngestLargeSourceBytes)

        let result = try ingestPhoto(request(bytes: bytes), into: storage)

        #expect(result.warnsLargeSource == true)
        #expect(result.width == 640)
        #expect(result.height == 480)
    }

    @Test("garbage bytes fail with a plain error and zero partial files")
    func decodeFailureLeavesNothing() throws {
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let garbage = Data("definitely not an image".utf8)

        let error = #expect(throws: PhotoIngestError.self) {
            try ingestPhoto(request(bytes: garbage), into: storage)
        }
        #expect(error?.code == "ingest_decode_failed")
        #expect(try storage.listPhotoFileRelativeURIs().isEmpty)
    }

    @Test("empty bytes fail with a plain error")
    func emptySourceFails() throws {
        let storage = MediaStorage(root: try makeTempMediaRoot())
        let error = #expect(throws: PhotoIngestError.self) {
            try ingestPhoto(request(bytes: Data()), into: storage)
        }
        #expect(error?.code == "ingest_empty_source")
        #expect(try storage.listPhotoFileRelativeURIs().isEmpty)
    }
}
