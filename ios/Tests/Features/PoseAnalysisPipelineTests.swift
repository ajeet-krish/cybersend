import CyberSendData
import CyberSendDomain
import Foundation
import Testing
@testable import CyberSendFeatures

// The end to end bridge: extraction, Tier A metrics, and storage in one call. The runner is
// stubbed so these tests never touch AVFoundation or Vision.

private struct StubRunner: PoseAnalysisRunning {
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

private func pipelineFrame(tMs: Int, x: Double, y: Double) -> PoseFrame {
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

/// Rise for a second and a half, hold, fall, then rest. Produces a real attempt window and fall.
private func pipelineRiseAndFallTrack() -> PoseTrack {
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
        return pipelineFrame(tMs: Int((time * 1000).rounded()), x: 0.5, y: y)
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

@Suite("Pose analysis pipeline")
struct PoseAnalysisPipelineTests {
    private func video(_ test: TestDatabase) throws -> Video {
        try test.repos.media.createVideo(CreateVideoInput(uri: "videos/clip.mov", fps: 60))
    }

    @Test("extraction, metrics, and storage happen in one call and mark the video done")
    func storesEverything() async throws {
        let test = try makeTestDatabase()
        let video = try video(test)
        let runner = StubRunner(track: pipelineRiseAndFallTrack())
        let pipeline = PoseAnalysisPipeline(repositories: test.repos, runner: runner)

        let result = try await pipeline.analyzeAndStore(
            videoId: video.id,
            videoURL: URL(fileURLWithPath: "/tmp/clip.mov")
        )

        let metrics = try #require(result.metrics)
        #expect(metrics.attemptWindow.detectedByMotion)
        #expect(result.analysis.cameraClass == .stationary)
        #expect(result.analysis.coverage > 0.9)
        #expect(result.analysis.algorithmVersion == TierAMetricsEngine.algorithmVersion)
        #expect(result.analysis.visionRevision == 3)
        #expect(result.analysis.samplingHz == 30)
        #expect(result.analysis.sourceWidth == 1080)
        #expect(result.analysis.sourceFPS == 60)
        #expect(result.analysis.needsRecompute == false)

        let stored = try test.repos.media.getVideo(id: video.id)
        #expect(stored?.poseStatus == .done)

        // The blob decodes back to the analysed track.
        let blob = try #require(result.analysis.trackBlob)
        let decoded = try PoseTrackCodec.decode(blob)
        #expect(decoded.frames.count == result.track.frames.count)
        #expect(decoded.sourceFPS == 60)

        let events = try test.repos.videoAnalysis.events(analysisId: result.analysis.id)
        #expect(events.count == 3)
        #expect(events.contains { $0.type == .attemptStart })
        #expect(events.contains { $0.type == .attemptEnd })
        let fall = try #require(events.first { $0.type == .fall })
        #expect(fall.confidence > 0.5)
        #expect(fall.value ?? 0 > 0.5)
    }

    @Test("quality flags name what limits the clip")
    func qualityFlagsDescribeTheClip() async throws {
        let test = try makeTestDatabase()
        let video = try video(test)
        let runner = StubRunner(track: pipelineRiseAndFallTrack())
        let pipeline = PoseAnalysisPipeline(repositories: test.repos, runner: runner)

        let result = try await pipeline.analyzeAndStore(
            videoId: video.id,
            videoURL: URL(fileURLWithPath: "/tmp/clip.mov")
        )

        let flags = Set(result.analysis.qualityFlags.split(separator: ",").map(String.init))
        #expect(flags.contains("low_coverage") == false)
        #expect(flags.contains("camera_handheld") == false)
        #expect(flags.contains("metrics_unavailable") == false)
    }

    @Test("a track with no metrics is still stored and cannot unlock comparison")
    func unusableMetricsAreStillStored() async throws {
        let test = try makeTestDatabase()
        let video = try video(test)
        let singleFrame = PoseTrack(
            samplingHz: 30,
            sourceWidth: 1080,
            sourceHeight: 1920,
            visionRevision: 3,
            frames: [pipelineFrame(tMs: 0, x: 0.5, y: 0.5)]
        )
        let pipeline = PoseAnalysisPipeline(
            repositories: test.repos,
            runner: StubRunner(track: singleFrame)
        )

        let result = try await pipeline.analyzeAndStore(
            videoId: video.id,
            videoURL: URL(fileURLWithPath: "/tmp/clip.mov")
        )

        #expect(result.metrics == nil)
        #expect(result.analysis.cameraClass == .handheld)
        #expect(result.analysis.trackBlob != nil)
        #expect(result.analysis.qualityFlags.contains("metrics_unavailable"))
        #expect(result.analysis.cameraClass.supportsComparison == false)

        let stored = try test.repos.media.getVideo(id: video.id)
        #expect(stored?.poseStatus == .done)
    }

    @Test("a failed run marks the video failed and stores nothing")
    func failureIsRecorded() async throws {
        let test = try makeTestDatabase()
        let video = try video(test)
        let pipeline = PoseAnalysisPipeline(
            repositories: test.repos,
            runner: StubRunner(error: .noPoseDetected)
        )

        await #expect(throws: PoseAnalysisError.noPoseDetected) {
            try await pipeline.analyzeAndStore(
                videoId: video.id,
                videoURL: URL(fileURLWithPath: "/tmp/clip.mov")
            )
        }

        let stored = try test.repos.media.getVideo(id: video.id)
        #expect(stored?.poseStatus == .failed)
        let record = try test.repos.videoAnalysis.analysis(videoId: video.id)
        #expect(record == nil)
    }

    @Test("a cancelled run returns the video to pending instead of marking it failed")
    func cancellationIsNotAFailure() async throws {
        let test = try makeTestDatabase()
        let video = try video(test)
        let pipeline = PoseAnalysisPipeline(
            repositories: test.repos,
            runner: StubRunner(error: .cancelled)
        )

        await #expect(throws: PoseAnalysisError.cancelled) {
            try await pipeline.analyzeAndStore(
                videoId: video.id,
                videoURL: URL(fileURLWithPath: "/tmp/clip.mov")
            )
        }

        let stored = try test.repos.media.getVideo(id: video.id)
        #expect(stored?.poseStatus == .pending, "a cancelled run leaves the clip analysable")
        #expect(try test.repos.videoAnalysis.analysis(videoId: video.id) == nil)
    }

    @Test("re-running replaces the previous analysis instead of adding a second one")
    func rerunReplaces() async throws {
        let test = try makeTestDatabase()
        let video = try video(test)
        let pipeline = PoseAnalysisPipeline(
            repositories: test.repos,
            runner: StubRunner(track: pipelineRiseAndFallTrack())
        )

        let first = try await pipeline.analyzeAndStore(
            videoId: video.id,
            videoURL: URL(fileURLWithPath: "/tmp/clip.mov")
        )
        let second = try await pipeline.analyzeAndStore(
            videoId: video.id,
            videoURL: URL(fileURLWithPath: "/tmp/clip.mov")
        )

        #expect(first.analysis.id != second.analysis.id)
        let analyses = try test.repos.videoAnalysis.listAnalyses()
        #expect(analyses.count == 1)
        #expect(analyses.first?.id == second.analysis.id)
        let oldEvents = try test.repos.videoAnalysis.events(analysisId: first.analysis.id)
        #expect(oldEvents.isEmpty)
    }
}
