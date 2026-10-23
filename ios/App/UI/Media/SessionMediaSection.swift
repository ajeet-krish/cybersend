import AVKit
import CyberSendDomain
import CyberSendFeatures
import PhotosUI
import SwiftUI

// Session media (UI overhaul): photos and clips attached to a session, available on open and
// closed sessions alike, which is what makes a photo or video retroactive. Photos come in
// through the one ingest pipeline; videos are imported as bytes and played with AVKit, no
// frames, no pose, no editing. Nothing here is uploaded (local first).

/// The session media block: a photo strip, a video list, and the two import buttons. It owns
/// its store so a screen body stays a description of layout.
struct SessionMediaSection: View {
    let sessionId: String
    let services: AppServices

    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var store: SessionMediaStore
    @State private var showPhotoImport = false
    @State private var showVideoImport = false
    @State private var showRecorder = false
    @State private var previewPhoto: Photo?
    @State private var playingVideo: Video?

    init(sessionId: String, services: AppServices) {
        self.sessionId = sessionId
        self.services = services
        _store = StateObject(wrappedValue: SessionMediaStore(
            repos: services.repos,
            storage: services.media.storage,
            sessionId: sessionId
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Session media")
            Card {
            if let message = store.lastErrorMessage {
                ErrorNote(message)
                    .accessibilityIdentifier("session.media.error")
            }
            if store.isEmpty {
                Text("Add a photo or a clip from the library. Everything stays on this device.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("session.media.empty")
            }
            if !store.photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(store.photos.enumerated()), id: \.element.id) { index, photo in
                            Button {
                                previewPhoto = photo
                            } label: {
                                photoThumb(photo)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("session.media.photo.\(index)")
                        }
                    }
                }
            }
            ForEach(Array(store.videos.enumerated()), id: \.element.id) { index, video in
                if index > 0 || !store.photos.isEmpty {
                    Divider()
                        .overlay(Theme.separator)
                        .padding(.vertical, 8)
                }
                Button {
                    playingVideo = video
                } label: {
                    videoRow(video, index: index)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("session.media.video.\(index)")
            }
        }

        HStack(spacing: 10) {
            Button {
                showPhotoImport = true
            } label: {
                Label("Add photo", systemImage: "photo")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("session.media.add-photo")

            Button {
                showVideoImport = true
            } label: {
                Label("Add video", systemImage: "video")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("session.media.add-video")
        }
        .disabled(store.isImporting)

        // Guided capture is gated on the pose flag (docs/architecture.md, Pose Pipeline): the
        // recorder exists to feed the analysis, so offering it while analysis is off would
        // promise something the app does not do.
        if settings.flags[.aiPoseAnalysis] {
            Button {
                showRecorder = true
            } label: {
                Label("Record a clip", systemImage: "video.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.isImporting)
            .accessibilityIdentifier("session.media.record")
        }
        }
        .sheet(isPresented: $showPhotoImport) {
            PhotoImportSheet { bytes in
                Task { await store.importPhoto(bytes: bytes) }
            }
        }
        .sheet(isPresented: $showVideoImport) {
            VideoImportSheet { bytes, fileExtension in
                Task { await store.importVideo(bytes: bytes, fileExtension: fileExtension) }
            }
        }
        .sheet(item: $previewPhoto) { photo in
            SessionPhotoPreview(
                photo: photo,
                url: store.fullPhotoURL(photo),
                onDelete: {
                    store.delete(photo: photo)
                    previewPhoto = nil
                }
            )
        }
        .sheet(item: $playingVideo) { video in
            SessionVideoPlayer(url: store.videoURL(video), title: videoTitle(video, index: indexOf(video)))
        }
        .fullScreenCover(isPresented: $showRecorder) {
            GuidedRecorderView { clip in
                Task { await store.importRecordedVideo(fileURL: clip.fileURL) }
            }
        }
        .onAppear {
            store.refresh()
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func photoThumb(_ photo: Photo) -> some View {
        Group {
            if let url = store.photoURL(photo) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Theme.surfaceRaised)
                }
            } else {
                Rectangle().fill(Theme.surfaceRaised)
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 1)
        )
    }

    private func videoRow(_ video: Video, index: Int) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surfaceRaised)
                Image(systemName: "play.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(videoTitle(video, index: index))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                if let duration = durationText(video) {
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("session.media.video.\(index).duration")
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "play.circle")
                .font(.title3)
                .foregroundStyle(Theme.secondaryText)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Labels

    private func indexOf(_ video: Video) -> Int {
        store.videos.firstIndex(where: { $0.id == video.id }) ?? 0
    }

    private func videoTitle(_ video: Video, index: Int) -> String {
        "Clip \(index + 1)"
    }

    private func durationText(_ video: Video) -> String? {
        guard let durationMs = video.durationMs, durationMs > 0 else { return nil }
        let totalSeconds = Int((Double(durationMs) / 1000).rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

// MARK: - Video import

/// Library video import: PhotosPicker returns clip bytes plus the content type, which gives
/// the file extension the storage layer needs. A load failure writes nothing.
struct VideoImportSheet: View {
    let onImport: (Data, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Screen {
                if let errorMessage {
                    ErrorNote(errorMessage)
                        .accessibilityIdentifier("video.import.error")
                }
                PhotosPicker(selection: $selection, matching: .videos) {
                    Label("Select a video", systemImage: "video.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("video.import.picker")
                Text("The clip is copied into this app, never uploaded, and plays without a network.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("video.import.note")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.screenBackground.ignoresSafeArea())
            .navigationTitle("Choose from library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("video.import.cancel")
                }
            }
        }
        .onChange(of: selection) { item in
            load(item)
        }
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        errorMessage = nil
        Task {
            do {
                guard let bytes = try await item.loadTransferable(type: Data.self), !bytes.isEmpty else {
                    errorMessage = "That video could not be loaded. Try another one."
                    return
                }
                let fileExtension = item.supportedContentTypes
                    .compactMap(\.preferredFilenameExtension)
                    .first ?? "mov"
                onImport(bytes, fileExtension)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Playback

/// Full screen clip playback (AVKit). Playback only: the player has no editing, trimming, or
/// frame export, matching the product decision for session video.
struct SessionVideoPlayer: View {
    let url: URL?
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    EmptyState(
                        systemImage: "video.slash",
                        title: "Clip unavailable",
                        message: "The video file is missing from this device."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.screenBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        player?.pause()
                        dismiss()
                    }
                    .accessibilityIdentifier("media.player.done")
                }
            }
        }
        .accessibilityIdentifier("media.player")
        .onAppear {
            guard let url else { return }
            player = AVPlayer(url: url)
            player?.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}

// MARK: - Photo preview

/// Full size session photo with a delete action, so the gallery is not append only.
struct SessionPhotoPreview: View {
    let photo: Photo
    let url: URL?
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Screen {
                if let url {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
                    .accessibilityIdentifier("session.media.photo.full")
                } else {
                    EmptyState(
                        systemImage: "photo",
                        title: "Photo unavailable",
                        message: "The file is missing from this device."
                    )
                }
                SecondaryButton("Delete photo") {
                    confirmDelete = true
                }
                .accessibilityIdentifier("session.media.photo.delete")
            }
            .navigationTitle("Session photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this photo?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete photo", role: .destructive) {
                onDelete()
            }
            .accessibilityIdentifier("session.media.photo.delete.confirm")
            Button("Keep", role: .cancel) {}
        }
    }
}
