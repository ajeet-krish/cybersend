import AVFoundation
import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import Foundation

// Session media store (UI overhaul): the photos and videos attached to one session, which
// is how an old session gets a photo or a clip after the fact. Photos run through the one
// ingest pipeline (the same decode and re-encode as a climb photo) with a nil climb and the
// session id; videos are copied bytes for byte into the videos directory and their
// dimensions and duration are read from the file, because nothing in this app edits video
// (playback only, per the product decision).

@MainActor
final class SessionMediaStore: ObservableObject {
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var videos: [Video] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isImporting = false

    let sessionId: String
    private let repos: Repositories
    private let storage: MediaStorage
    private let photoStore: PhotoStore

    init(repos: Repositories, storage: MediaStorage, sessionId: String) {
        self.repos = repos
        self.storage = storage
        self.sessionId = sessionId
        self.photoStore = PhotoStore(repos: repos, storage: storage)
        refresh()
    }

    var isEmpty: Bool {
        photos.isEmpty && videos.isEmpty
    }

    func refresh() {
        do {
            photos = try repos.media.listPhotos(filter: ListPhotosFilter(sessionId: sessionId))
                .sorted { $0.capturedAt > $1.capturedAt }
            videos = try repos.media.listVideos(options: ListVideosOptions(sessionId: sessionId))
                .sorted { $0.createdAt < $1.createdAt }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Imports library image bytes as a session photo and reloads the gallery.
    func importPhoto(bytes: Data, source: PhotoSource = .library) async {
        isImporting = true
        defer { isImporting = false }
        do {
            _ = try await photoStore.addSessionPhoto(bytes: bytes, source: source, sessionId: sessionId)
            refresh()
        } catch {
            lastErrorMessage = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    /// Imports library video bytes: the clip is written under videos/ untouched, then a row
    /// records the session link plus the metadata playback needs. A clip whose metadata
    /// cannot be read is still imported (nil dimensions and duration) rather than rejected.
    func importVideo(bytes: Data, fileExtension: String) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let fileID = UUID().uuidString.lowercased()
            let uri = try storage.writeVideo(bytes, videoID: fileID, fileExtension: fileExtension)
            let url = try storage.url(relativeURI: uri)
            let metadata = await Self.probe(url: url)
            _ = try repos.media.createVideo(CreateVideoInput(
                uri: uri,
                sessionId: sessionId,
                climbId: nil,
                width: metadata.width,
                height: metadata.height,
                durationMs: metadata.durationMs,
                fps: nil,
                poseStatus: .none,
                retentionClass: .keep
            ))
            refresh()
        } catch {
            lastErrorMessage = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    /// Adopts a clip recorded in the guided recorder (P4). The file is moved out of the
    /// temporary directory rather than read into memory, so a long clip costs no extra peak
    /// memory, and the row is marked pending because the pose feature that offered the recorder
    /// is on by construction. The same probe reads the real dimensions off the written file.
    func importRecordedVideo(fileURL: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let fileID = UUID().uuidString.lowercased()
            let uri = try storage.adoptVideo(fileAt: fileURL, videoID: fileID, fileExtension: "mov")
            let url = try storage.url(relativeURI: uri)
            let metadata = await Self.probe(url: url)
            _ = try repos.media.createVideo(CreateVideoInput(
                uri: uri,
                sessionId: sessionId,
                climbId: nil,
                width: metadata.width,
                height: metadata.height,
                durationMs: metadata.durationMs,
                fps: nil,
                poseStatus: .pending,
                retentionClass: .keep
            ))
            refresh()
        } catch {
            lastErrorMessage = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    func delete(photo: Photo) {
        do {
            try? storage.deletePhotoFiles(photo: photo)
            try repos.media.deletePhoto(id: photo.id)
            refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func delete(video: Video) {
        do {
            try? storage.delete(relativeURI: video.uri)
            try repos.media.deleteVideo(id: video.id)
            refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func photoURL(_ photo: Photo) -> URL? {
        try? storage.url(relativeURI: photo.thumbUri ?? photo.uri)
    }

    func fullPhotoURL(_ photo: Photo) -> URL? {
        try? storage.url(relativeURI: photo.uri)
    }

    func videoURL(_ video: Video) -> URL? {
        try? storage.url(relativeURI: video.uri)
    }

    /// Reads duration and pixel size off the written file. The track's preferred transform
    /// is applied so a portrait clip reports portrait dimensions.
    nonisolated private static func probe(url: URL) async -> (width: Int?, height: Int?, durationMs: Int?) {
        let asset = AVURLAsset(url: url)
        var width: Int?
        var height: Int?
        var durationMs: Int?
        if let duration = try? await asset.load(.duration) {
            let milliseconds = (duration.seconds * 1000).rounded()
            if milliseconds.isFinite, milliseconds > 0 {
                durationMs = Int(milliseconds)
            }
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let oriented = size.applying(transform)
                width = Int(abs(oriented.width).rounded())
                height = Int(abs(oriented.height).rounded())
            }
        }
        return (width, height, durationMs)
    }
}
