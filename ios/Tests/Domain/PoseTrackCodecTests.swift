import Foundation
import Testing
@testable import CyberSendDomain

// Packed pose track codec: the storage format behind video_analyses.track_blob.

private func sample(_ x: Double, _ y: Double, _ confidence: Double, interpolated: Bool = false) -> JointSample {
    JointSample(x: x, y: y, confidence: confidence, isInterpolated: interpolated)
}

@Test func poseTrackRoundTripsThroughThePackedFormat() throws {
    let frames = [
        PoseFrame(tMs: 0, joints: [
            .neck: sample(0.5, 0.25, 0.75),
            .leftWrist: sample(0.25, 0.5, 0.5),
            .rightHip: sample(0.75, 0.75, 0.25, interpolated: true),
        ]),
        PoseFrame(tMs: 33, joints: [:]),
        PoseFrame(tMs: 66, joints: [
            .leftWrist: sample(0.125, 0.375, 0.5),
        ]),
    ]
    let track = PoseTrack(
        samplingHz: 30,
        sourceWidth: 720,
        sourceHeight: 1280,
        sourceFPS: 240,
        visionRevision: 3,
        frames: frames
    )

    let decoded = try PoseTrackCodec.decode(PoseTrackCodec.encode(track))

    #expect(decoded.samplingHz == 30)
    #expect(decoded.sourceWidth == 720)
    #expect(decoded.sourceHeight == 1280)
    #expect(decoded.sourceFPS == 240)
    #expect(decoded.visionRevision == 3)
    #expect(decoded.frames.count == 3)
    #expect(decoded.frames[0].joints[.neck] == sample(0.5, 0.25, 0.75))
    #expect(decoded.frames[0].joints[.rightHip]?.isInterpolated == true)
    #expect(decoded.frames[1].joints.isEmpty)
    #expect(decoded.frames[2].tMs == 66)
}

@Test func unknownSourceFPSStaysNil() throws {
    let track = PoseTrack(
        samplingHz: 30,
        sourceWidth: 320,
        sourceHeight: 240,
        sourceFPS: nil,
        visionRevision: 1,
        frames: [PoseFrame(tMs: 0, joints: [:])]
    )
    let decoded = try PoseTrackCodec.decode(PoseTrackCodec.encode(track))
    #expect(decoded.sourceFPS == nil)
}

@Test func packedSizeIsAboutOneHundredBytesPerFrame() throws {
    let track = PoseTrack(
        samplingHz: 30,
        sourceWidth: 720,
        sourceHeight: 1280,
        visionRevision: 1,
        frames: (0..<900).map { index in
            PoseFrame(
                tMs: index * 33,
                joints: Dictionary(uniqueKeysWithValues: PoseJoint.core.map { ($0, sample(0.5, 0.5, 0.9)) })
            )
        }
    )
    let data = PoseTrackCodec.encode(track)
    #expect(data.count > 90_000)
    #expect(data.count < 130_000, "a 30 second track must stay in the ~103 KB range")
}

@Test func rejectsForeignBytes() {
    #expect(throws: PoseTrackCodecError.badMagic) {
        _ = try PoseTrackCodec.decode(Data("not a pose track".utf8))
    }
}

@Test func rejectsTruncatedBytes() throws {
    let track = PoseTrack(
        samplingHz: 30,
        sourceWidth: 720,
        sourceHeight: 1280,
        visionRevision: 1,
        frames: [PoseFrame(tMs: 0, joints: [.neck: sample(0.5, 0.5, 0.75)])]
    )
    let full = PoseTrackCodec.encode(track)
    let truncated = full.prefix(full.count - 4)
    #expect(throws: PoseTrackCodecError.truncated) {
        _ = try PoseTrackCodec.decode(Data(truncated))
    }
}
