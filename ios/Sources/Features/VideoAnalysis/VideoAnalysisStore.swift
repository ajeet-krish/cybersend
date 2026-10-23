import Combine
import CyberSendData
import CyberSendDomain
import Foundation

// Video analysis store (P5). The screen facing half of the pose pipeline: which clips exist,
// which have an analysis, which is running right now, and what the stored track says.
//
// Metrics are never stored. They are recomputed from the packed track on demand, which keeps one
// source of truth (the track) and means a threshold change applies to every clip without a
// migration. A stored analysis whose blob was dropped by a backup restore simply reports nil.

@MainActor
public final class VideoAnalysisStore: ObservableObject {
    public struct ClipRow: Identifiable, Equatable, Sendable {
        public var video: Video
        public var analysis: VideoAnalysis?
        /// Non nil only while an analysis is running for this clip.
        public var progress: PoseAnalysisProgress?

        public var id: String { video.id }

        public var isAnalyzing: Bool { progress != nil }

        public init(video: Video, analysis: VideoAnalysis? = nil, progress: PoseAnalysisProgress? = nil) {
            self.video = video
            self.analysis = analysis
            self.progress = progress
        }

        /// True when the row carries metadata but no track, which is what a restore produces.
        public var needsRecompute: Bool {
            analysis?.needsRecompute == true
        }
    }

    @Published public private(set) var clips: [ClipRow] = []
    @Published public private(set) var lastErrorMessage: String?

    private let repos: Repositories
    private let storage: MediaStorage
    private let pipeline: PoseAnalysisPipeline
    private let crashGuard: PoseCrashGuard
    private var runningVideoIDs: Set<String> = []

    public init(
        repositories: Repositories,
        storage: MediaStorage,
        runner: any PoseAnalysisRunning = VisionPoseAnalysisRunner(),
        thresholds: MetricThresholds = MetricThresholds(),
        crashGuard: PoseCrashGuard = PoseCrashGuard()
    ) {
        self.repos = repositories
        self.storage = storage
        self.pipeline = PoseAnalysisPipeline(
            repositories: repositories,
            runner: runner,
            thresholds: thresholds
        )
        self.crashGuard = crashGuard
    }

    // MARK: - Loading

    public func refresh() {
        do {
            let videos = try repos.media.listVideos(options: ListVideosOptions())
            var byVideo: [String: VideoAnalysis] = [:]
            for analysis in try repos.videoAnalysis.listAnalyses() {
                byVideo[analysis.videoId] = analysis
            }
            var runningProgress: [String: PoseAnalysisProgress] = [:]
            for clip in clips {
                runningProgress[clip.id] = clip.progress
            }
            clips = videos
                .sorted { $0.createdAt > $1.createdAt }
                .map { video in
                    ClipRow(
                        video: video,
                        analysis: byVideo[video.id],
                        progress: runningProgress[video.id]
                    )
                }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func clip(id: String) -> ClipRow? {
        clips.first { $0.id == id }
    }

    public func videoURL(for clip: ClipRow) -> URL? {
        try? storage.url(relativeURI: clip.video.uri)
    }

    // MARK: - Running

    /// Analyses one clip and reloads its row. Re-analysis replaces the previous record, which is
    /// what the repository already enforces.
    public func analyze(videoId: String) async {
        guard !runningVideoIDs.contains(videoId) else { return }
        lastErrorMessage = nil
        guard let video = try? repos.media.getVideo(id: videoId) else {
            lastErrorMessage = "That clip is no longer in the library."
            return
        }
        guard let url = try? storage.url(relativeURI: video.uri) else {
            lastErrorMessage = "The clip file is missing, so it cannot be analysed."
            return
        }

        runningVideoIDs.insert(videoId)
        // The marker is written only once the run is actually about to start, so a missing file or
        // a bad row above cannot leave a marker that looks like a crash at the next launch.
        crashGuard.begin(videoId: videoId)
        setProgress(
            PoseAnalysisProgress(
                framesProcessed: 0,
                estimatedTotalFrames: nil,
                currentMs: 0,
                averageCoverage: 0
            ),
            for: videoId
        )
        defer {
            crashGuard.clear()
            runningVideoIDs.remove(videoId)
            setProgress(nil, for: videoId)
            refresh()
        }

        do {
            _ = try await pipeline.analyzeAndStore(
                videoId: videoId,
                videoURL: url,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        self?.setProgress(progress, for: videoId)
                    }
                }
            )
            lastErrorMessage = nil
        } catch PoseAnalysisError.cancelled {
            lastErrorMessage = "Analysis cancelled."
        } catch is CancellationError {
            lastErrorMessage = "Analysis cancelled."
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Derived results

    /// Metrics recomputed from the stored track. Nil when there is no analysis, the blob was
    /// dropped by a restore, or the track is too short to prepare.
    public func metrics(videoId: String) throws -> TierAMetrics? {
        guard
            let analysis = try repos.videoAnalysis.analysis(videoId: videoId),
            let blob = analysis.trackBlob
        else { return nil }
        let track = try PoseTrackCodec.decode(blob)
        return TierAMetricsEngine.compute(track: track)
    }

    public func events(videoId: String) throws -> [AnalysisEvent] {
        guard let analysis = try repos.videoAnalysis.analysis(videoId: videoId) else { return [] }
        return try repos.videoAnalysis.events(analysisId: analysis.id)
    }

    /// Decoded track for the overlay and timeline. Nil when the blob is absent.
    public func track(videoId: String) throws -> PoseTrack? {
        guard
            let analysis = try repos.videoAnalysis.analysis(videoId: videoId),
            let blob = analysis.trackBlob
        else { return nil }
        return try PoseTrackCodec.decode(blob)
    }

    public func deleteAnalysis(videoId: String) {
        do {
            try repos.videoAnalysis.deleteAnalysis(videoId: videoId)
            refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Progress

    private func setProgress(_ progress: PoseAnalysisProgress?, for videoId: String) {
        if let index = clips.firstIndex(where: { $0.id == videoId }) {
            clips[index].progress = progress
        }
    }
}
