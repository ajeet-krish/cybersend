import CyberSendData
import CyberSendDomain
import Foundation
import Testing
@testable import CyberSendFeatures

// Video analysis store (P5): listing clips, running analysis through the pipeline, and
// recomputing metrics from the stored track. The runner is stubbed, so no camera or Vision.

private struct StoreStubRunner: PoseAnalysisRunning {
    var track: PoseTrack?
    var error: PoseAnalysisError?

    func analyze(
        videoURL: URL,
        stride: Int?,
        startAfterMs: Int?,
        progress: @Sendable (PoseAnalysisProgress) -> Void
    ) async throws -> PoseAnalysisResult {
        if let error { throw error }
        guard let track else { throw PoseAnalysisError.emptyTrack }
        let quality = PoseTrackQuality.measure(track)
        progress(
            PoseAnalysisProgress(
                framesProcessed: track.frames.count,
                estimatedTotalFrames: track.frames.count,
                currentMs: track.frames.last?.tMs ?? 0,
                averageCoverage: quality.averageCoverage
            )
        )
        return PoseAnalysisResult(track: track, quality: quality)
    }
}

private func storeFrame(tMs: Int, x: Double, y: Double) -> PoseFrame {
    var joints: [PoseJoint: JointSample] = [:]
    func put(_ joint: PoseJoint, _ px: Double, _ py: Double) {
        joints[joint] = JointSample(x: px, y: py, confidence: 0.9)
    }
    put(.nose, x, y - 0.30)
    put(.neck, x, y - 0.20)
    put(.leftShoulder, x - 0.05, y - 0.15)
    put(.rightShoulder, x + 0.05, y - 0.15)
    put(.leftHip, x - 0.04, y + 0.10)
    put(.rightHip, x + 0.04, y + 0.10)
    put(.leftWrist, x - 0.10, y + 0.06)
    put(.rightWrist, x + 0.10, y + 0.06)
    put(.leftKnee, x - 0.04, y + 0.22)
    put(.rightKnee, x + 0.04, y + 0.22)
    put(.leftAnkle, x - 0.04, y + 0.35)
    put(.rightAnkle, x + 0.04, y + 0.35)
    put(.root, x, y + 0.10)
    return PoseFrame(tMs: tMs, joints: joints)
}

private func storeRiseAndFallTrack() -> PoseTrack {
    let hz = 30.0
    let frames = (0..<Int(4.5 * hz)).map { index -> PoseFrame in
        let time = Double(index) / hz
        let y: Double
        if time < 1.0 {
            y = 0.75
        } else if time < 2.5 {
            y = 0.75 - (time - 1.0) / 1.5 * 0.5
        } else if time < 3.0 {
            y = 0.25
        } else if time < 3.4 {
            y = 0.25 + (time - 3.0) / 0.4 * 0.5
        } else {
            y = 0.75
        }
        return storeFrame(tMs: Int((time * 1000).rounded()), x: 0.5, y: y)
    }
    return PoseTrack(
        samplingHz: hz,
        sourceWidth: 1080,
        sourceHeight: 1920,
        sourceFPS: 60,
        visionRevision: 3,
        frames: frames
    )
}

@MainActor
@Suite("Video analysis store")
struct VideoAnalysisStoreTests {
    private func makeStore(
        runner: StoreStubRunner,
        test: TestDatabase
    ) throws -> (store: VideoAnalysisStore, storage: MediaStorage) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cybersend-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = MediaStorage(root: root)
        let store = VideoAnalysisStore(
            repositories: test.repos,
            storage: storage,
            runner: runner
        )
        return (store, storage)
    }

    @Test("a clip without an analysis lists with no result")
    func listsUnanalysedClips() throws {
        let test = try makeTestDatabase()
        _ = try test.repos.media.createVideo(CreateVideoInput(uri: "videos/a.mov"))
        let (store, _) = try makeStore(runner: StoreStubRunner(track: nil), test: test)

        store.refresh()

        #expect(store.clips.count == 1)
        #expect(store.clips[0].analysis == nil)
        #expect(store.clips[0].needsRecompute == false)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("analyzing a clip stores it and the metrics recompute from the track")
    func analyzeAndDeriveMetrics() async throws {
        let test = try makeTestDatabase()
        let video = try test.repos.media.createVideo(CreateVideoInput(uri: "videos/b.mov"))
        let (store, _) = try makeStore(
            runner: StoreStubRunner(track: storeRiseAndFallTrack()),
            test: test
        )
        store.refresh()

        await store.analyze(videoId: video.id)

        #expect(store.lastErrorMessage == nil)
        let clip = try #require(store.clip(id: video.id))
        #expect(clip.analysis != nil)
        #expect(clip.isAnalyzing == false)
        #expect(clip.video.poseStatus == .done)

        let metrics = try store.metrics(videoId: video.id)
        let unwrapped = try #require(metrics)
        #expect(unwrapped.attemptWindow.detectedByMotion)
        #expect(unwrapped.fallEvents.count == 1)

        let events = try store.events(videoId: video.id)
        #expect(events.count == 3)

        let track = try store.track(videoId: video.id)
        #expect(track?.frames.count == storeRiseAndFallTrack().frames.count)
    }

    @Test("a restored analysis without a track reports needsRecompute and yields no metrics")
    func restoredAnalysisNeedsRecompute() async throws {
        let test = try makeTestDatabase()
        let video = try test.repos.media.createVideo(CreateVideoInput(uri: "videos/c.mov"))
        let (store, _) = try makeStore(
            runner: StoreStubRunner(track: storeRiseAndFallTrack()),
            test: test
        )
        store.refresh()
        await store.analyze(videoId: video.id)

        try await test.writer.write { db in
            try db.execute(sql: "UPDATE video_analyses SET track_blob = NULL")
        }
        store.refresh()

        let clip = try #require(store.clip(id: video.id))
        #expect(clip.needsRecompute)
        let metrics = try store.metrics(videoId: video.id)
        #expect(metrics == nil)
        let track = try store.track(videoId: video.id)
        #expect(track == nil)
    }

    @Test("a failed analysis reports the reason and leaves no record")
    func failedAnalysis() async throws {
        let test = try makeTestDatabase()
        let video = try test.repos.media.createVideo(CreateVideoInput(uri: "videos/d.mov"))
        let (store, _) = try makeStore(
            runner: StoreStubRunner(error: .noPoseDetected),
            test: test
        )
        store.refresh()

        await store.analyze(videoId: video.id)

        let message = try #require(store.lastErrorMessage)
        #expect(message.contains("No person"))
        #expect(try test.repos.videoAnalysis.analysis(videoId: video.id) == nil)
        #expect(store.clip(id: video.id)?.video.poseStatus == .failed)
        #expect(store.clip(id: video.id)?.isAnalyzing == false)
    }
}
