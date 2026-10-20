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
}
