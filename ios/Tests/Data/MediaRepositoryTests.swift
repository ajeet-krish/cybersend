import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain

// Media repository tests: photos, videos, and pose keypoint rows (backup coverage from
// phase 1; capture flows land in M3 and M6).

@Suite("MediaRepository")
struct MediaRepositoryTests {
    @Test("creates a photo and filters by climb")
    func photoLifecycle() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)

        let photo = try test.repos.media.createPhoto(
            CreatePhotoInput(uri: "photos/wall.heic", width: 2048, height: 1536, climbId: climbId, thumbUri: "photos/thumb.heic")
        )
        #expect(photo.source == .camera)
        #expect(try test.repos.media.getPhoto(id: photo.id) == photo)

        let listed = try test.repos.media.listPhotos(filter: ListPhotosFilter(climbId: climbId))
        #expect(listed.map(\.id) == [photo.id])
        #expect(try test.repos.media.listPhotos().count == 1)

        try test.repos.media.updatePhotoThumb(id: photo.id, thumbUri: nil)
        #expect(try test.repos.media.getPhoto(id: photo.id)?.thumbUri == nil)

        try test.repos.media.deletePhoto(id: photo.id)
        #expect(try test.repos.media.getPhoto(id: photo.id) == nil)
    }

    @Test("library photos store their source")
    func libraryPhotoSource() throws {
        let test = try makeTestDatabase()
        let photo = try test.repos.media.createPhoto(
            CreatePhotoInput(uri: "photos/pick.jpg", width: 100, height: 100, source: .library)
        )
        #expect(photo.source == .library)
    }

    @Test("createPhoto honors an injected row id (M3 ingest writes the files first)")
    func createPhotoInjectedID() throws {
        let test = try makeTestDatabase()
        let injected = generateID()

        let photo = try test.repos.media.createPhoto(CreatePhotoInput(
            id: injected, uri: "photos/working/\(injected).jpg", width: 10, height: 10
        ))

        #expect(photo.id == injected)
        #expect(try test.repos.media.getPhoto(id: injected) == photo)

        // Without the override the repository generates a UUID like before.
        let generated = try test.repos.media.createPhoto(CreatePhotoInput(uri: "photos/other.jpg", width: 1, height: 1))
        #expect(UUID(uuidString: generated.id) != nil)
    }

    @Test("creates videos with defaults and filters by retention class")
    func videoLifecycle() throws {
        let test = try makeTestDatabase()
        let video = try test.repos.media.createVideo(CreateVideoInput(uri: "videos/clip.mp4", durationMs: 30_000, fps: 60))

        #expect(video.poseStatus == .none)
        #expect(video.retentionClass == .ephemeral)
        #expect(try test.repos.media.getVideo(id: video.id) == video)
        #expect(try test.repos.media.listVideos().map(\.id) == [video.id])

        try test.repos.media.updateVideo(id: video.id, patch: UpdateVideoPatch(poseStatus: .set(.done), retentionClass: .set(.keep)))
        #expect(try test.repos.media.getVideo(id: video.id)?.poseStatus == .done)
        #expect(try test.repos.media.listVideos(options: ListVideosOptions(retentionClass: .keep)).count == 1)
        #expect(try test.repos.media.listVideos(options: ListVideosOptions(retentionClass: .ephemeral)).isEmpty)

        try test.repos.media.deleteVideo(id: video.id)
        #expect(try test.repos.media.getVideo(id: video.id) == nil)
    }

    @Test("pose keypoints list ordered by timestamp and cascade with the video")
    func poseKeypoints() throws {
        let test = try makeTestDatabase()
        let video = try test.repos.media.createVideo(CreateVideoInput(uri: "videos/clip.mp4"))

        _ = try test.repos.media.addPoseKeypoint(AddPoseKeypointInput(videoId: video.id, tMs: 200, keypointsJson: "[0.1,0.2]"))
        _ = try test.repos.media.addPoseKeypoint(AddPoseKeypointInput(videoId: video.id, tMs: 100, score: 0.9, keypointsJson: "[0.3,0.4]"))

        let keypoints = try test.repos.media.listPoseKeypoints(videoId: video.id)
        #expect(keypoints.map(\.tMs) == [100, 200])
        #expect(keypoints.first?.score == 0.9)

        // Deleting the video cascades to its keypoints (schema ON DELETE CASCADE).
        try test.repos.media.deleteVideo(id: video.id)
        #expect(try test.repos.media.listPoseKeypoints(videoId: video.id).isEmpty)
    }

    @Test("originalUri round trips through create, get, and the dump (M3)")
    func originalUriRoundTrip() throws {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)

        let photo = try test.repos.media.createPhoto(CreatePhotoInput(
            uri: "photos/wall.jpg",
            width: 2048,
            height: 1536,
            climbId: climbId,
            thumbUri: "photos/wall_thumb.jpg",
            originalUri: "originals/wall_original.jpg"
        ))
        #expect(photo.originalUri == "originals/wall_original.jpg")
        #expect(try test.repos.media.getPhoto(id: photo.id) == photo)

        let dump = try test.repos.dump.dumpAll()
        #expect(dump[.photos][0]["original_uri"] == .text("originals/wall_original.jpg"))

        // The discard path stores nil, which round trips as null.
        let discarded = try test.repos.media.createPhoto(CreatePhotoInput(
            uri: "photos/no_original.jpg", width: 100, height: 100
        ))
        #expect(discarded.originalUri == nil)
        #expect(try test.repos.media.getPhoto(id: discarded.id) == discarded)
    }

    @Test("listAllPhotos returns every photo for the retention sweep (M3)")
    func listAllPhotos() throws {
        let test = try makeTestDatabase()
        let (gymId, climbId) = try seedGymAndClimb(test.repos)
        let session = try test.repos.sessions.create(CreateSessionInput(gymId: gymId))

        let onClimb = try test.repos.media.createPhoto(CreatePhotoInput(
            uri: "photos/a.jpg", width: 10, height: 10, climbId: climbId, originalUri: "originals/a.jpg"
        ))
        let onSession = try test.repos.media.createPhoto(CreatePhotoInput(
            uri: "photos/b.jpg", width: 10, height: 10, sessionId: session.id
        ))
        let orphan = try test.repos.media.createPhoto(CreatePhotoInput(uri: "photos/c.jpg", width: 10, height: 10))

        let all = try test.repos.media.listAllPhotos()
        #expect(Set(all.map(\.id)) == Set([onClimb.id, onSession.id, orphan.id]))
        // The sweep can see which photos still reference an original.
        #expect(all.filter { $0.originalUri != nil }.map(\.id) == [onClimb.id])
    }

    @Test("updatePhoto patches the file fields and rejects unknown ids (M3)")
    func updatePhotoPatch() throws {
        let test = try makeTestDatabase()
        let photo = try test.repos.media.createPhoto(CreatePhotoInput(
            uri: "photos/working/a.jpg", width: 2048, height: 1536,
            thumbUri: "photos/thumbs/a.jpg", originalUri: "photos/originals/a.jpg", source: .library
        ))

        // The replace flow rewrites every file field in one write.
        let replaced = try test.repos.media.updatePhoto(id: photo.id, patch: UpdatePhotoPatch(
            uri: .set("photos/working/b.jpg"),
            thumbUri: .set("photos/thumbs/b.jpg"),
            originalUri: .set(nil),
            width: .set(1024),
            height: .set(768)
        ))
        #expect(replaced.uri == "photos/working/b.jpg")
        #expect(replaced.thumbUri == "photos/thumbs/b.jpg")
        #expect(replaced.originalUri == nil)
        #expect(replaced.width == 1024)
        #expect(replaced.height == 768)
        #expect(replaced.source == .library, "source and timestamps are not part of the patch")
        #expect(try test.repos.media.getPhoto(id: photo.id) == replaced)

        // The tagging save discard clears only the original uri.
        let discarded = try test.repos.media.updatePhoto(id: photo.id, patch: UpdatePhotoPatch(
            originalUri: .set("photos/originals/c.jpg")
        ))
        #expect(discarded.originalUri == "photos/originals/c.jpg")
        #expect(discarded.uri == "photos/working/b.jpg")

        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.media.updatePhoto(id: "missing", patch: UpdatePhotoPatch(width: .set(1)))
        }
        #expect(error?.code == "photo_not_found")
    }

    @Test("deletePhotos removes every listed row in one batch (M3 sweep)")
    func deletePhotosBatch() throws {
        let test = try makeTestDatabase()
        let first = try test.repos.media.createPhoto(CreatePhotoInput(uri: "photos/a.jpg", width: 1, height: 1))
        let second = try test.repos.media.createPhoto(CreatePhotoInput(uri: "photos/b.jpg", width: 1, height: 1))
        let third = try test.repos.media.createPhoto(CreatePhotoInput(uri: "photos/c.jpg", width: 1, height: 1))

        try test.repos.media.deletePhotos(ids: [first.id, third.id, "unknown-id"])

        #expect(try test.repos.media.listAllPhotos().map(\.id) == [second.id])

        // The empty batch is a no op.
        try test.repos.media.deletePhotos(ids: [])
        #expect(try test.repos.media.listAllPhotos().count == 1)
    }
}
