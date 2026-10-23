import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Clips surface (P5): every clip the app knows about, with its analysis state, opening the
// review screen. It is a pushed screen under Stats rather than a sixth tab, because the tab bar
// already holds five destinations and a sixth would collapse into a More tab.
//
// The list reads status from the video row and the analysis record only. Metrics are not loaded
// here: decoding every stored track to build a list would cost more than the list is worth.

struct VideosView: View {
    let services: AppServices

    @StateObject private var store: VideoAnalysisStore

    init(services: AppServices) {
        self.services = services
        _store = StateObject(wrappedValue: VideoAnalysisStore(
            repositories: services.repos,
            storage: services.media.storage
        ))
    }

    var body: some View {
        Screen {
            if let message = store.lastErrorMessage {
                ErrorNote(message)
                    .accessibilityIdentifier("videos.error")
            }

            if store.clips.isEmpty {
                EmptyState(
                    systemImage: "video",
                    title: "No clips yet",
                    message: "Record a clip from a session or add one from the library. Analysis runs on this device."
                )
                .accessibilityIdentifier("videos.empty")
            } else {
                SectionTitle("Clips")
                Card {
                    ForEach(Array(store.clips.enumerated()), id: \.element.id) { index, clip in
                        NavigationLink {
                            VideoReviewView(videoId: clip.id, services: services)
                        } label: {
                            row(clip, index: index)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("videos.row.\(index)")

                        if index < store.clips.count - 1 {
                            Divider()
                                .overlay(Theme.separator)
                                .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
        .navigationTitle("Clips")
        .accessibilityIdentifier("videos.screen")
        .onAppear {
            store.refresh()
        }
    }

    private func row(_ clip: VideoAnalysisStore.ClipRow, index: Int) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surfaceRaised)
                Image(systemName: "video.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text("Clip \(index + 1)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                Text(detailText(clip))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer(minLength: 8)

            Text(statusText(clip))
                .font(.caption.weight(.medium))
                .foregroundStyle(statusTint(clip))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusTint(clip).opacity(0.12), in: Capsule())
        }
        .contentShape(Rectangle())
    }

    private func detailText(_ clip: VideoAnalysisStore.ClipRow) -> String {
        var parts: [String] = []
        parts.append(DisplayDate.string(from: clip.video.createdAt))
        if let duration = clip.video.durationMs, duration > 0 {
            let seconds = max(0, duration) / 1000
            parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        return parts.joined(separator: "  ")
    }

    private func statusText(_ clip: VideoAnalysisStore.ClipRow) -> String {
        if clip.isAnalyzing { return "Analyzing" }
        if clip.analysis?.needsRecompute == true { return "Track missing" }
        switch clip.video.poseStatus {
        case .done: return "Analysed"
        case .failed: return "Failed"
        case .running: return "Analyzing"
        case .pending: return "Not analysed"
        case .none: return "No analysis"
        }
    }

    private func statusTint(_ clip: VideoAnalysisStore.ClipRow) -> Color {
        if clip.isAnalyzing { return Theme.accent }
        if clip.analysis?.needsRecompute == true { return Theme.warning }
        switch clip.video.poseStatus {
        case .done: return Theme.success
        case .failed: return Theme.danger
        case .running: return Theme.accent
        case .pending, .none: return Theme.secondaryText
        }
    }
}
