import CyberSendData
import CyberSendDomain
import Foundation

/// Everything one pipeline run produced, so a caller can show a summary without re-reading the
/// database.
public struct PosePipelineResult: Sendable {
    public var analysis: VideoAnalysis
    public var metrics: TierAMetrics?
    public var track: PoseTrack
    public var quality: PoseTrackQuality

    public init(
        analysis: VideoAnalysis,
        metrics: TierAMetrics?,
        track: PoseTrack,
        quality: PoseTrackQuality
    ) {
        self.analysis = analysis
        self.metrics = metrics
        self.track = track
        self.quality = quality
    }
}

/// Extraction, Tier A metrics, and storage as one unit.
///
/// The three steps are useless separately: a stored track without metrics is invisible to the UI,
/// and metrics without a stored track vanish when the app closes. Keeping them in one actor also
/// enforces the thermal rule from docs/architecture.md, because exactly one analysis runs at a
/// time and the actor queue is the lock.
///
/// A track that yields no metrics is still stored. Throwing away a usable pose track because the
/// maths could not scale the body would force an expensive re-extraction later, and the record
/// carries `metrics_unavailable` so the UI can say why nothing was measured.
public actor PoseAnalysisPipeline {
    /// Bumped when extraction or metrics change in a way that makes old analyses incomparable.
    public nonisolated static var algorithmVersion: Int { TierAMetricsEngine.algorithmVersion }

    private let runner: any PoseAnalysisRunning
    private let repos: Repositories
    private let thresholds: MetricThresholds

    public init(
        repositories: Repositories,
        runner: any PoseAnalysisRunning = VisionPoseAnalysisRunner(),
        thresholds: MetricThresholds = MetricThresholds()
    ) {
        self.repos = repositories
        self.runner = runner
        self.thresholds = thresholds
    }

    /// Analyses `videoURL` for `videoId`, stores the track and its events, and returns both the
    /// stored record and the computed metrics.
    ///
    /// The video row must already exist, otherwise `poseStatus` stays untouched and the analysis
    /// insert fails its foreign key.
    public func analyzeAndStore(
        videoId: String,
        videoURL: URL,
        stride: Int? = nil,
        progress: @escaping @Sendable (PoseAnalysisProgress) -> Void = { _ in }
    ) async throws -> PosePipelineResult {
        try repos.media.updateVideo(
            id: videoId,
            patch: UpdateVideoPatch(poseStatus: .set(.running))
        )

        do {
            let extracted = try await runner.analyze(
                videoURL: videoURL,
                stride: stride,
                startAfterMs: nil,
                progress: progress
            )
            let metrics = TierAMetricsEngine.compute(track: extracted.track, thresholds: thresholds)

            let input = SaveAnalysisInput(
                videoId: videoId,
                algorithmVersion: Self.algorithmVersion,
                visionRevision: extracted.track.visionRevision,
                samplingHz: extracted.track.samplingHz,
                sourceWidth: extracted.track.sourceWidth,
                sourceHeight: extracted.track.sourceHeight,
                sourceFPS: extracted.track.sourceFPS,
                // An unclassified clip is treated as handheld, the least privileged class, so a
                // missing metric can never unlock comparison it did not earn.
                cameraClass: metrics?.cameraClass ?? .handheld,
                coverage: extracted.quality.averageCoverage,
                qualityFlags: Self.qualityFlags(metrics: metrics, quality: extracted.quality)
                    .joined(separator: ","),
                track: extracted.track,
                events: (metrics?.events ?? []).map(Self.eventInput)
            )

            let stored = try repos.videoAnalysis.saveAnalysis(input)
            try repos.media.updateVideo(
                id: videoId,
                patch: UpdateVideoPatch(poseStatus: .set(.done))
            )

            return PosePipelineResult(
                analysis: stored,
                metrics: metrics,
                track: extracted.track,
                quality: extracted.quality
            )
        } catch {
            try? repos.media.updateVideo(
                id: videoId,
                patch: UpdateVideoPatch(poseStatus: .set(.failed))
            )
            throw error
        }
    }

    nonisolated static func eventInput(_ event: DetectedEvent) -> AnalysisEventInput {
        AnalysisEventInput(
            type: event.type,
            startMs: event.startMs,
            endMs: event.endMs,
            joint: event.joint,
            xNorm: event.xNorm,
            yNorm: event.yNorm,
            value: event.value,
            confidence: event.confidence
        )
    }

    /// Stable, comma separated tokens describing how much the clip can be trusted. Tokens rather
    /// than prose because the review screen groups and filters on them.
    nonisolated static func qualityFlags(
        metrics: TierAMetrics?,
        quality: PoseTrackQuality
    ) -> [String] {
        var flags: [String] = []
        if !quality.isUsableForMetrics {
            flags.append("low_coverage")
        }
        guard let metrics else {
            flags.append("metrics_unavailable")
            return flags
        }
        if metrics.bodyScale.usedFallback {
            flags.append("body_scale_fallback")
        }
        if !metrics.bodyScale.isReliable {
            flags.append("body_scale_unstable")
        }
        if metrics.cameraClass == .handheld {
            flags.append("camera_handheld")
        }
        if !metrics.attemptWindow.detectedByMotion {
            flags.append("no_attempt")
        }
        if !metrics.isUsable {
            flags.append("metrics_low_confidence")
        }
        return flags
    }
}
