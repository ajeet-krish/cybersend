import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import CyberSendDomain
@testable import CyberSendFeatures

// P1 pose extraction: sampling policy, orientation derivation, track assembly, and the
// AVFoundation reader walking a real generated clip. No device and no camera are needed.

// MARK: - Sampling policy

@Test func strideLeavesNormalRatesAlone() {
    #expect(FrameSampling.recommendedStride(forFPS: nil) == 1)
    #expect(FrameSampling.recommendedStride(forFPS: 24) == 1)
    #expect(FrameSampling.recommendedStride(forFPS: 30) == 1)
    #expect(FrameSampling.recommendedStride(forFPS: 59.94) == 1)
    #expect(FrameSampling.recommendedStride(forFPS: 60) == 1)
}

@Test func strideDecimatesSlowMotion() {
    #expect(FrameSampling.recommendedStride(forFPS: 61) == 2)
    #expect(FrameSampling.recommendedStride(forFPS: 120) == 2)
    #expect(FrameSampling.recommendedStride(forFPS: 240) == 4)
    #expect(FrameSampling.recommendedStride(forFPS: 0) == 1)
    #expect(FrameSampling.recommendedStride(forFPS: -30) == 1)
}

@Test func effectiveFPSDividesByStride() {
    #expect(FrameSampling.effectiveFPS(sourceFPS: 240, stride: 4) == 60)
    #expect(FrameSampling.effectiveFPS(sourceFPS: 30, stride: 1) == 30)
    #expect(FrameSampling.effectiveFPS(sourceFPS: nil, stride: 1) == nil)
}

// MARK: - Orientation

@Test func orientationFromIdentityIsUp() {
    #expect(AssetReaderVideoFrameReader.deriveOrientation(from: .identity) == .up)
}

@Test func orientationFromQuarterTurns() {
    let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
    #expect(AssetReaderVideoFrameReader.deriveOrientation(from: portrait) == .right)

    let upsideDown = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
    #expect(AssetReaderVideoFrameReader.deriveOrientation(from: upsideDown) == .down)

    let otherPortrait = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
    #expect(AssetReaderVideoFrameReader.deriveOrientation(from: otherPortrait) == .left)
}

@Test func orientationFromMirroredTransform() {
    let mirroredUp = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    #expect(AssetReaderVideoFrameReader.deriveOrientation(from: mirroredUp) == .upMirrored)
    #expect(VideoOrientation.upMirrored.isMirrored)
}

@Test func orientationSwapsDimensionsOnlyForQuarterTurns() {
    #expect(VideoOrientation.right.swapsDimensions)
    #expect(VideoOrientation.left.swapsDimensions)
    #expect(!VideoOrientation.up.swapsDimensions)
    #expect(!VideoOrientation.down.swapsDimensions)

    let display = AssetReaderVideoFrameReader.displayDimensions(
        naturalSize: CGSize(width: 1920, height: 1080),
        orientation: .right
    )
    #expect(display == CGSize(width: 1080, height: 1920))
}

@Test func analysisBufferIsScaledToLongEdge() {
    let wide = AssetReaderVideoFrameReader.encodedBufferSize(
        naturalSize: CGSize(width: 1920, height: 1080)
    )
    #expect(wide.width == 720)
    #expect(wide.height == 406)

    let small = AssetReaderVideoFrameReader.encodedBufferSize(
        naturalSize: CGSize(width: 320, height: 240)
    )
    #expect(small.width == 320)
    #expect(small.height == 240)
}

// MARK: - Track assembly and quality

private func joints(_ pairs: [(PoseJoint, Double)]) -> [PoseJoint: JointSample] {
    var result: [PoseJoint: JointSample] = [:]
    for (joint, confidence) in pairs {
        result[joint] = JointSample(x: 0.5, y: 0.5, confidence: confidence)
    }
    return result
}

@Test func coverageCountsOnlyUsableCoreJoints() {
    let frame = PoseFrame(tMs: 0, joints: joints([
        (.neck, 0.9), (.leftShoulder, 0.9), (.rightShoulder, 0.9),
        (.leftHip, 0.9), (.rightHip, 0.1), (.leftWrist, 0.9),
    ]))
    // 12 core joints, 5 usable.
    #expect(abs(frame.coverage - (5.0 / 12.0)) < 1e-9)
    #expect(frame.isUsable == false)

    let strong = PoseFrame(tMs: 0, joints: joints(PoseJoint.core.map { ($0, 0.9) }))
    #expect(strong.coverage == 1)
    #expect(strong.isUsable)
}

@Test func interpolatedSamplesNeverCountAsCoverage() {
    var map = joints(PoseJoint.core.map { ($0, 0.9) })
    map[.neck] = JointSample(x: 0.5, y: 0.5, confidence: 0.9, isInterpolated: true)
    let frame = PoseFrame(tMs: 0, joints: map)
    #expect(frame.coverage < 1)
}

@Test func qualityFlagsAGapHeavyTrackAsUnusable() {
    let usable = PoseFrame(tMs: 0, joints: joints(PoseJoint.core.map { ($0, 0.9) }))
    let usableAgain = PoseFrame(tMs: 1000, joints: joints(PoseJoint.core.map { ($0, 0.9) }))
    let empty = PoseFrame(tMs: 500, joints: [:])
    let track = PoseTrack(
        samplingHz: 30,
        sourceWidth: 720,
        sourceHeight: 1280,
        visionRevision: 1,
        frames: [usable, empty, empty, empty, usableAgain]
    )
    let quality = PoseTrackQuality.measure(track)
    #expect(quality.averageCoverage == 0.4)
    #expect(quality.emptyFrameFraction == 0.6)
    #expect(quality.longestGapMs == 500)
    #expect(quality.isUsableForMetrics == false)
}

@Test func emptyTrackQualityIsZero() {
    let track = PoseTrack(
        samplingHz: 30,
        sourceWidth: 720,
        sourceHeight: 1280,
        visionRevision: 1,
        frames: []
    )
    let quality = PoseTrackQuality.measure(track)
    #expect(quality.averageCoverage == 0)
    #expect(quality.emptyFrameFraction == 1)
    #expect(quality.isUsableForMetrics == false)
}

@Test func observationOrderingIsDeterministic() {
    let big = PoseObservation(
        joints: [:],
        confidence: 0.5,
        boundingBox: PoseRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
    )
    let small = PoseObservation(
        joints: [:],
        confidence: 0.9,
        boundingBox: PoseRect(x: 0.7, y: 0.1, width: 0.2, height: 0.2)
    )
    #expect(PoseObservationOrdering.sorted([big, small]).first == big)
    #expect(PoseObservationOrdering.sorted([small, big]).first == big)
}

// MARK: - Frame reader against a generated clip

private enum TestClipError: Error {
    case writerUnavailable
    case bufferUnavailable
    case appendFailed
}

private func writeTestClip(
    frameCount: Int,
    fps: Int32 = 30,
    size: CGSize = CGSize(width: 160, height: 120)
) async throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cybersend_pose_\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
    )
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
    )

    guard writer.canAdd(input) else { throw TestClipError.writerUnavailable }
    writer.add(input)
    guard writer.startWriting() else { throw TestClipError.writerUnavailable }
    writer.startSession(atSourceTime: .zero)

    for index in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw TestClipError.bufferUnavailable
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0x40, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let ok = adaptor.append(
            pixelBuffer,
            withPresentationTime: CMTime(value: Int64(index), timescale: fps)
        )
        if !ok { throw TestClipError.appendFailed }
    }

    input.markAsFinished()
    await writer.finishWriting()
    return url
}

@Test func readerReportsClipMetadata() async throws {
    let url = try await writeTestClip(frameCount: 15, fps: 30)
    defer { try? FileManager.default.removeItem(at: url) }

    let reader = try await AssetReaderVideoFrameReader.make(url: url)
    #expect(reader.metadata.width == 160)
    #expect(reader.metadata.height == 120)
    #expect(reader.metadata.nominalFPS != nil)
    #expect(reader.metadata.durationMs > 0)
    #expect(reader.metadata.orientation == .up)
    #expect(reader.metadata.isHDR == false)
}

@Test func readerHonoursStride() async throws {
    let url = try await writeTestClip(frameCount: 20, fps: 30)
    defer { try? FileManager.default.removeItem(at: url) }

    let reader = try await AssetReaderVideoFrameReader.make(url: url)
    var timestamps: [Int] = []
    try reader.read(stride: 2, startAfterMs: nil) { frame in
        timestamps.append(frame.tMs)
        return true
    }
    #expect(timestamps.count == 10)
    #expect(timestamps.first == 0)
    #expect(timestamps == timestamps.sorted())
}

@Test func readerStopsWhenCallbackReturnsFalse() async throws {
    let url = try await writeTestClip(frameCount: 30, fps: 30)
    defer { try? FileManager.default.removeItem(at: url) }

    let reader = try await AssetReaderVideoFrameReader.make(url: url)
    var count = 0
    try reader.read(stride: 1, startAfterMs: nil) { _ in
        count += 1
        return count < 4
    }
    #expect(count == 4)
}

@Test func readerResumesAfterTimestamp() async throws {
    let url = try await writeTestClip(frameCount: 30, fps: 30)
    defer { try? FileManager.default.removeItem(at: url) }

    let reader = try await AssetReaderVideoFrameReader.make(url: url)
    var timestamps: [Int] = []
    try reader.read(stride: 1, startAfterMs: 300) { frame in
        timestamps.append(frame.tMs)
        return true
    }
    #expect(timestamps.allSatisfy { $0 > 300 })
    #expect(!timestamps.isEmpty)
}

// MARK: - Architecture guard

@Test func domainPoseLayerNeverImportsVision() throws {
    // Structural guard for the decision that metrics stay pure. #filePath is a compile time
    // path, so this resolves in the repository and is skipped in a packaged bundle.
    let testFile = URL(fileURLWithPath: #filePath)
    let poseDirectory = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/Domain/Pose")

    guard FileManager.default.fileExists(atPath: poseDirectory.path) else { return }
    let files = try FileManager.default.contentsOfDirectory(
        at: poseDirectory,
        includingPropertiesForKeys: nil
    )
    for file in files where file.pathExtension == "swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("import Vision"), "\(file.lastPathComponent) imports Vision")
        #expect(!text.contains("import AVFoundation"), "\(file.lastPathComponent) imports AVFoundation")
        #expect(!text.contains("import UIKit"), "\(file.lastPathComponent) imports UIKit")
    }
}
