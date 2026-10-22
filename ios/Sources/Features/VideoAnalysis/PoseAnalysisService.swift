import CyberSendDomain
import Foundation

/// Progress for one running analysis. Delivered on an arbitrary executor, so the UI must hop to
/// the main actor before touching published state.
public struct PoseAnalysisProgress: Sendable, Equatable {
    public var framesProcessed: Int
    public var estimatedTotalFrames: Int?
    public var currentMs: Int
    /// Running average coverage, so the UI can show "tracking" or "losing subject".
    public var averageCoverage: Double

    public init(
        framesProcessed: Int,
        estimatedTotalFrames: Int?,
        currentMs: Int,
        averageCoverage: Double
    ) {
        self.framesProcessed = framesProcessed
        self.estimatedTotalFrames = estimatedTotalFrames
        self.currentMs = currentMs
        self.averageCoverage = averageCoverage
    }

    public var fraction: Double? {
        guard let total = estimatedTotalFrames, total > 0 else { return nil }
        return min(1, Double(framesProcessed) / Double(total))
    }
}

/// Result of one completed analysis.
public struct PoseAnalysisResult: Sendable, Equatable {
    public var track: PoseTrack
    public var quality: PoseTrackQuality

    public init(track: PoseTrack, quality: PoseTrackQuality) {
        self.track = track
        self.quality = quality
    }
}

/// Analysis entry point.
///
/// A protocol rather than a concrete runner so the store can be tested with a deterministic
/// fixture track and so a different detector stack can be swapped in behind the same surface.
public protocol PoseAnalysisRunning: Sendable {
    func analyze(
        videoURL: URL,
        stride: Int?,
        startAfterMs: Int?,
        progress: @Sendable (PoseAnalysisProgress) -> Void
    ) async throws -> PoseAnalysisResult
}

/// Ties the frame reader and the pose detector together.
///
/// An actor because VNSequenceRequestHandler and AVAssetReader are both single use and not safe
/// to share, and because exactly one analysis should run at a time on a phone (thermal budget).
/// The work runs off the main actor; the caller only sees progress callbacks and a final result.
public actor VisionPoseAnalysisRunner: PoseAnalysisRunning {
    public init() {}

    public func analyze(
        videoURL: URL,
        stride: Int?,
        startAfterMs: Int?,
        progress: @Sendable (PoseAnalysisProgress) -> Void
    ) async throws -> PoseAnalysisResult {
        let reader = try await AssetReaderVideoFrameReader.make(url: videoURL)
        let metadata = reader.metadata
        let resolvedStride = max(1, stride ?? FrameSampling.recommendedStride(forFPS: metadata.nominalFPS))
        let detector = VisionPoseDetector()

        let estimatedTotal = Self.estimateFrameCount(metadata: metadata, stride: resolvedStride)
        var frames: [PoseFrame] = []
        frames.reserveCapacity(min(estimatedTotal ?? 900, 20000))
        var coverageSum = 0.0

        try reader.read(stride: resolvedStride, startAfterMs: startAfterMs) { decoded in
            if Task.isCancelled { throw PoseAnalysisError.cancelled }

            let observations = try detector.detect(
                on: decoded.pixelBuffer,
                orientation: decoded.orientation
            )
            // The plan says never guess the subject silently, so this is a deterministic first
            // choice only; subject correction belongs to the review UI.
            let primary = PoseObservationOrdering.sorted(observations).first
            let frame = PoseFrame(tMs: decoded.tMs, joints: primary?.joints ?? [:])
            frames.append(frame)
            coverageSum += frame.coverage

            let processed = frames.count
            if processed % 15 == 0 {
                progress(
                    PoseAnalysisProgress(
                        framesProcessed: processed,
                        estimatedTotalFrames: estimatedTotal,
                        currentMs: decoded.tMs,
                        averageCoverage: coverageSum / Double(processed)
                    )
                )
            }
            return true
        }

        guard !frames.isEmpty else { throw PoseAnalysisError.emptyTrack }

        let effectiveHz = FrameSampling.effectiveFPS(
            sourceFPS: metadata.nominalFPS,
            stride: resolvedStride
        ) ?? 30

        let track = PoseTrack(
            samplingHz: effectiveHz,
            sourceWidth: metadata.width,
            sourceHeight: metadata.height,
            sourceFPS: metadata.nominalFPS,
            visionRevision: detector.revision,
            frames: frames
        )
        let quality = PoseTrackQuality.measure(track)

        if quality.emptyFrameFraction >= 1 {
            throw PoseAnalysisError.noPoseDetected
        }

        progress(
            PoseAnalysisProgress(
                framesProcessed: frames.count,
                estimatedTotalFrames: estimatedTotal,
                currentMs: frames.last?.tMs ?? 0,
                averageCoverage: quality.averageCoverage
            )
        )

        return PoseAnalysisResult(track: track, quality: quality)
    }

    static func estimateFrameCount(metadata: VideoMetadata, stride: Int) -> Int? {
        guard
            let fps = metadata.nominalFPS,
            fps.isFinite,
            fps > 0,
            metadata.durationMs > 0
        else { return nil }
        let frames = Int((Double(metadata.durationMs) / 1000 * fps / Double(stride)).rounded())
        return max(1, frames)
    }
}
