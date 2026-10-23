import AVKit
import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Clip review (P5): playback, pose overlay, the attempt timeline, the Tier A summary, and the
// one action that produces all of it.
//
// Everything numeric on this screen is a relative measurement in body heights, recomputed from
// the stored track. Nothing here is a force, a velocity in metres, or a comparison against
// another climber, because Tier A cannot support those claims (docs/decisions.md, 2026-10-21
// Phase 5 record).

struct VideoReviewView: View {
    let videoId: String
    let services: AppServices

    @StateObject private var store: VideoAnalysisStore
    @State private var player: ClipPlayerModel?
    @State private var track: PoseTrack?
    @State private var metrics: TierAMetrics?
    @State private var showsOverlay = true
    /// The running analysis, held so the screen can cancel it. Cancelling the task cancels the
    /// extraction loop, which checks for cancellation between frames.
    @State private var analysisTask: Task<Void, Never>?
    @State private var confirmsDelete = false

    init(videoId: String, services: AppServices) {
        self.videoId = videoId
        self.services = services
        _store = StateObject(wrappedValue: VideoAnalysisStore(
            repositories: services.repos,
            storage: services.media.storage
        ))
    }

    private var clip: VideoAnalysisStore.ClipRow? {
        store.clip(id: videoId)
    }

    private var videoSize: CGSize {
        guard let clip else { return CGSize(width: 1080, height: 1920) }
        let width = clip.video.width ?? 1080
        let height = clip.video.height ?? 1920
        return CGSize(width: width, height: height)
    }

    var body: some View {
        Screen {
            if let player {
                ClipPlayerCard(
                    player: player,
                    videoSize: videoSize,
                    frame: frame(at: player.currentMs),
                    metrics: metrics,
                    showsOverlay: $showsOverlay
                )
            } else {
                Card {
                    Text("The clip file is missing, so it cannot be played or analysed.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("video.review.missing")
                }
            }

            analysisSection

            if let metrics {
                summarySection(metrics)
            }

            if let clip {
                flagsSection(clip)
            }
        }
        .navigationTitle("Clip")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("video.review.screen")
        .onAppear {
            loadResults()
            ensurePlayer()
        }
        .onDisappear {
            player?.stop()
            // Leaving the screen stops the work rather than finishing it invisibly. The clip
            // returns to pending, so nothing is lost and the run can start again.
            analysisTask?.cancel()
        }
        .confirmationDialog(
            "Remove this analysis?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Remove analysis", role: .destructive) {
                store.deleteAnalysis(videoId: videoId)
                loadResults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The clip stays. The pose track and its events are deleted.")
        }
    }

    // MARK: - Analysis state

    @ViewBuilder
    private var analysisSection: some View {
        SectionTitle("Analysis")
        Card {
            if let clip, clip.isAnalyzing, let progress = clip.progress {
                progressBody(progress, isRunning: true)
            } else if analysisTask != nil {
                progressBody(nil, isRunning: true)
            } else if let analysis = clip?.analysis {
                analysedBody(analysis)
            } else if clip?.video.poseStatus == .failed {
                failedBody
            } else {
                pendingBody
            }
        }
    }

    private func progressBody(_ progress: PoseAnalysisProgress?, isRunning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reading the clip")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.primaryText)
            if let progress, let total = progress.estimatedTotalFrames, total > 0 {
                ProgressView(value: Double(progress.framesProcessed), total: Double(total))
                    .tint(Theme.accent)
                Text("\(Int(Double(progress.framesProcessed) / Double(total) * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ProgressView()
                    .tint(Theme.accent)
            }
            Text("Vision runs on this device. Nothing is uploaded.")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
            if isRunning {
                Button("Cancel") {
                    cancelAnalysis()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("video.cancel")
            }
        }
        .accessibilityIdentifier("video.progress")
    }

    private func analysedBody(_ analysis: VideoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statusChip(
                    analysis.needsRecompute ? "Track missing" : "Analysed",
                    tint: analysis.needsRecompute ? Theme.warning : Theme.success
                )
                statusChip(cameraLabel(analysis.cameraClass), tint: Theme.secondaryText)
                Spacer(minLength: 0)
            }
            if analysis.needsRecompute {
                Text("The pose track was not included in the backup, so metrics cannot be shown until the clip is analysed again.")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            HStack(spacing: 10) {
                Button {
                    runAnalysis()
                } label: {
                    Label("Analyze again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("video.reanalyze")

                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("video.remove-analysis")
            }
            .disabled(analysisTask != nil)
        }
    }

    private var pendingBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This clip has no analysis yet.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            Text("Analysis finds the body in each frame and measures vertical progress, the attempt window, falls, and smoothness. It runs on this device and takes about as long as the clip.")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
            Button {
                runAnalysis()
            } label: {
                Label("Analyze clip", systemImage: "figure.climbing")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(analysisTask != nil)
            .accessibilityIdentifier("video.analyze")
        }
    }

    private var failedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = store.lastErrorMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("video.analysis.error")
            }
            Text("The clip was kept. A different angle or a steadier phone may work better.")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
            Button {
                runAnalysis()
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(analysisTask != nil)
            .accessibilityIdentifier("video.analyze")
        }
    }

    // MARK: - Summary

    private func summarySection(_ metrics: TierAMetrics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("What the clip shows")
            Card {
                if !metrics.isUsable {
                    Text("This clip does not pass the usability bar. Treat the numbers as a rough read, not a measurement.")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .padding(.bottom, 10)
                }
                statRow("Attempt", timeText(metrics.attemptWindow.durationMs)) {
                    Text(
                        metrics.attemptWindow.detectedByMotion
                            ? "Detected from movement"
                            : "Clip edges, no movement detected"
                    )
                }
                divider
                statRow("Highest point", String(format: "%.2f body heights", metrics.highestPoint?.value ?? 0)) {
                    Text("Above the lowest point in the clip")
                }
                divider
                statRow("Falls", "\(metrics.fallEvents.count)") {
                    Text(metrics.fallEvents.isEmpty ? "No fall detected" : "Detected from a fast downward move")
                }
                if let peakSpeed = metrics.peakSpeed {
                    divider
                    statRow("Peak speed", String(format: "%.2f body heights per second", peakSpeed)) {
                        Text("Relative to the climber's body, not metres")
                    }
                }
                if let smoothness = metrics.smoothness {
                    divider
                    statRow("Smoothness", String(format: "%.2f", smoothness)) {
                        Text("Higher means a steadier path")
                    }
                }
                if let efficiency = metrics.pathEfficiency {
                    divider
                    statRow("Path efficiency", String(format: "%.0f%%", efficiency * 100)) {
                        Text("Straightness of the body centroid path")
                    }
                }
                divider
                statRow("Joint coverage", String(format: "%.0f%%", metrics.quality * 100)) {
                    Text("How much of the body Vision saw")
                }
                divider
                statRow("Camera", cameraLabel(metrics.cameraClass)) {
                    Text(
                        metrics.cameraClass.supportsComparison
                            ? "Stable enough to compare with other clips"
                            : "Handheld, so comparison with other clips is disabled"
                    )
                }
            }
            .accessibilityIdentifier("video.summary")
        }
    }

    private func statRow(
        _ label: String,
        _ value: String,
        @ViewBuilder detail: () -> Text
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 8)
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
            }
            detail()
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private var divider: some View {
        Divider()
            .overlay(Theme.separator)
            .padding(.vertical, 8)
    }

    // MARK: - Flags

    private func flagsSection(_ clip: VideoAnalysisStore.ClipRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Trust")
            Card {
                let flags = flagLabels(clip.analysis)
                if flags.isEmpty {
                    Text("No quality flags on this clip.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    FlowChips(items: flags)
                }
                if let analysis = clip.analysis, analysis.algorithmVersion != TierAMetricsEngine.algorithmVersion {
                    Text("Quality flags came from algorithm version \(analysis.algorithmVersion); the current version is \(TierAMetricsEngine.algorithmVersion).")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.top, 10)
                }
                if let warnings = metrics?.warnings, !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .accessibilityIdentifier("video.flags")
        }
    }

    private func flagLabels(_ analysis: VideoAnalysis?) -> [String] {
        guard let analysis else { return [] }
        return analysis.qualityFlags
            .split(separator: ",")
            .map { token in
                switch token {
                case "low_coverage": return "Low joint coverage"
                case "metrics_unavailable": return "No metrics for this clip"
                case "body_scale_fallback": return "Body scale from the torso"
                case "body_scale_unstable": return "Body scale unstable"
                case "camera_handheld": return "Handheld camera"
                case "no_attempt": return "No attempt window"
                case "metrics_low_confidence": return "Below the usability bar"
                default: return String(token)
                }
            }
    }

    // MARK: - Helpers

    private func statusChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func cameraLabel(_ cameraClass: CameraStabilityClass) -> String {
        switch cameraClass {
        case .stationary: return "Tripod"
        case .nearStatic: return "Nearly still"
        case .handheld: return "Handheld"
        }
    }

    private func timeText(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    /// The analysed frame at or before the playhead. Frames are stored at a fixed sample rate,
    /// so a binary search is exact and cheap enough to run on every clock tick.
    private func frame(at milliseconds: Int) -> PoseFrame? {
        guard let track, !track.frames.isEmpty else { return nil }
        var low = 0
        var high = track.frames.count - 1
        var best: PoseFrame?
        while low <= high {
            let mid = (low + high) / 2
            let frame = track.frames[mid]
            if frame.tMs <= milliseconds {
                best = frame
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best ?? track.frames.first
    }

    private func loadResults() {
        store.refresh()
        track = try? store.track(videoId: videoId)
        metrics = try? store.metrics(videoId: videoId)
    }

    private func ensurePlayer() {
        guard player == nil, let clip, let url = store.videoURL(for: clip) else { return }
        player = ClipPlayerModel(url: url)
    }

    private func runAnalysis() {
        guard analysisTask == nil else { return }
        player?.pause()
        analysisTask = Task {
            await store.analyze(videoId: videoId)
            analysisTask = nil
            loadResults()
            ensurePlayer()
        }
    }

    private func cancelAnalysis() {
        analysisTask?.cancel()
    }
}

// MARK: - Player card

private struct ClipPlayerCard: View {
    @ObservedObject var player: ClipPlayerModel
    let videoSize: CGSize
    let frame: PoseFrame?
    let metrics: TierAMetrics?
    @Binding var showsOverlay: Bool

    var body: some View {
        Card {
            ZStack {
                ClipPlayerLayerView(player: player.player)
                    .aspectRatio(videoSize.width / max(1, videoSize.height), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if showsOverlay, let frame {
                    SkeletonOverlay(frame: frame, videoSize: videoSize)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            transport
            if let metrics {
                ProgressTimeline(
                    metrics: metrics,
                    currentMs: player.currentMs,
                    durationMs: max(player.durationMs, metrics.attemptWindow.endMs),
                    onSeek: { player.seek(toMs: $0) }
                )
                .padding(.top, 10)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("video.play")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Text("\(timeText(player.currentMs)) / \(timeText(max(player.durationMs, metrics?.attemptWindow.endMs ?? 0)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier("video.clock")

            Spacer(minLength: 8)

            if frame != nil {
                Toggle(isOn: $showsOverlay) {
                    Text("Pose")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("video.overlay-toggle")
            }
        }
        .padding(.top, 12)
    }

    private func timeText(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

// MARK: - Chips

/// Wrapping chip row. A plain HStack truncates on a phone, and the flags are the part of the
/// screen a climber is most likely to need to read in full.
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { item in
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(Theme.primaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.surfaceRaised, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Two chips per row keeps the longest labels ("Below the usability bar") readable at the
    /// standard screen width without a layout pass.
    private var rows: [[String]] {
        stride(from: 0, to: items.count, by: 2).map { start in
            Array(items[start..<min(start + 2, items.count)])
        }
    }
}
