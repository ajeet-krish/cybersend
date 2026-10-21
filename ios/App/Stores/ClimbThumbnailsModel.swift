import CyberSendData
import CyberSendFeatures
import Foundation

// Climb photo thumbnails for the logbook rows (M3, US-17): one model per launch maps
// climb id to the thumbnail file URL so the quick log list renders AsyncImage rows
// without per row queries. Refresh is one listAllPhotos pass plus an existence check
// per photo (personal scale), and rows only read the published map, so the list stays
// smooth while scrolling (docs/architecture.md M3 app layer).

@MainActor
final class ClimbThumbnailsModel: ObservableObject {
    /// Climb id to the thumbnail file URL (falls back to the working copy when a row
    /// predates a thumb).
    @Published private(set) var thumbURLs: [String: URL] = [:]

    private let repos: Repositories
    private let storage: MediaStorage

    init(repos: Repositories, storage: MediaStorage) {
        self.repos = repos
        self.storage = storage
    }

    /// The thumbnail file URL for a climb's photo, or nil when it has none.
    func thumbURL(for climbId: String) -> URL? {
        thumbURLs[climbId]
    }

    /// Reloads the map from the photos table. Best effort: a query failure leaves the
    /// previous map instead of failing the logbook screen.
    func refresh() {
        let photos = (try? repos.media.listAllPhotos()) ?? []
        var map: [String: URL] = [:]
        for photo in photos {
            guard let climbId = photo.climbId, map[climbId] == nil else { continue }
            let uri = photo.thumbUri ?? photo.uri
            guard
                let url = try? storage.url(relativeURI: uri),
                FileManager.default.fileExists(atPath: url.path)
            else { continue }
            map[climbId] = url
        }
        thumbURLs = map
    }
}
