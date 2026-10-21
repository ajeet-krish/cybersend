import Combine
import CyberSendData
import CyberSendDomain
import Foundation

// Photo store (M3, US-17 and US-20.2): one photo per climb on the climb editor. The
// ingest pipeline is a Sendable value transformation and runs off the main actor; row
// writes stay on the main actor through the repositories (docs/decisions.md, Observable
// object per feature stores, synchronous repository calls). Failures publish
// lastErrorMessage and rethrow so the screen can present and the store stays the single
// source of truth for the climb photo.

@MainActor
public final class PhotoStore: ObservableObject {
    /// The climb's photo (the most recently captured one), or nil when there is none.
    @Published public private(set) var photo: Photo?
    @Published public private(set) var lastErrorMessage: String?
    /// Set after replacing the photo of a climb that already has holds: their
    /// coordinates were tuned to the old image and may need a review before tagging
    /// continues (US-18 and US-19 flow).
    @Published public private(set) var replaceWarnsHolds: Bool = false

    private let repos: Repositories
    private let storage: MediaStorage

    public init(repos: Repositories, storage: MediaStorage) {
        self.repos = repos
        self.storage = storage
    }

    /// Loads the climb's photo (latest by capture time) and clears transient state.
    public func load(climbId: String) {
        do {
            photo = try repos.media.listPhotos(filter: ListPhotosFilter(climbId: climbId)).first
            replaceWarnsHolds = false
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Ingests new bytes and creates the photo row for the climb. US-20.2 keeps one
    /// photo per climb, so a climb that already has one throws photo_already_exists and
    /// nothing is written; replacePhoto is the path for new bytes.
    @discardableResult
    public func addPhoto(
        bytes: Data,
        source: PhotoSource,
        climbId: String,
        sessionId: String? = nil
    ) async throws -> Photo {
        do {
            let existing = try repos.media.listPhotos(filter: ListPhotosFilter(climbId: climbId))
            guard existing.isEmpty else {
                throw DomainValidationError(
                    "photo_already_exists",
                    "This climb already has a photo. Replace it or delete it first."
                )
            }
            let capturedAt = nowISO8601()
            let result = try await runIngest(PhotoIngestRequest(
                photoID: generateID(),
                bytes: bytes,
                source: source,
                capturedAt: capturedAt,
                retention: currentRetention(),
                climbId: climbId,
                sessionId: sessionId
            ))
            let created = try repos.media.createPhoto(CreatePhotoInput(
                id: result.photoID,
                uri: result.workingUri,
                width: result.width,
                height: result.height,
                climbId: climbId,
                sessionId: sessionId,
                thumbUri: result.thumbUri,
                originalUri: result.originalUri,
                source: source,
                capturedAt: capturedAt
            ))
            photo = created
            replaceWarnsHolds = false
            lastErrorMessage = nil
            return created
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Ingests a photo attached to a session rather than a climb (UI overhaul: retroactive
    /// session media). A session holds a gallery, so unlike addPhoto there is no
    /// one-photo-per-owner rule and nothing is loaded into the published climb photo.
    @discardableResult
    public func addSessionPhoto(
        bytes: Data,
        source: PhotoSource,
        sessionId: String
    ) async throws -> Photo {
        do {
            let capturedAt = nowISO8601()
            let result = try await runIngest(PhotoIngestRequest(
                photoID: generateID(),
                bytes: bytes,
                source: source,
                capturedAt: capturedAt,
                retention: currentRetention(),
                climbId: nil,
                sessionId: sessionId
            ))
            let created = try repos.media.createPhoto(CreatePhotoInput(
                id: result.photoID,
                uri: result.workingUri,
                width: result.width,
                height: result.height,
                climbId: nil,
                sessionId: sessionId,
                thumbUri: result.thumbUri,
                originalUri: result.originalUri,
                source: source,
                capturedAt: capturedAt
            ))
            lastErrorMessage = nil
            return created
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Re-ingests new bytes over the current photo: the working copy, thumb, and
    /// retained original are rewritten in place under the same id and the row is patched
    /// in one write. An original retained by the previous capture that the new
    /// retention discards is deleted here, so replace honors the preference without a
    /// tagging save. The replaceWarnsHolds flag reports whether the climb already has
    /// holds whose coordinates may no longer match the new image.
    @discardableResult
    public func replacePhoto(bytes: Data, source: PhotoSource) async throws -> Photo {
        do {
            guard let current = photo else {
                throw DomainValidationError("photo_not_found", "There is no photo to replace.")
            }
            let result = try await runIngest(PhotoIngestRequest(
                photoID: current.id,
                bytes: bytes,
                source: source,
                capturedAt: current.capturedAt,
                retention: currentRetention(),
                climbId: current.climbId,
                sessionId: current.sessionId
            ))
            let updated = try repos.media.updatePhoto(id: current.id, patch: UpdatePhotoPatch(
                uri: .set(result.workingUri),
                thumbUri: .set(result.thumbUri),
                originalUri: .set(result.originalUri),
                width: .set(result.width),
                height: .set(result.height)
            ))
            if let oldOriginal = current.originalUri, oldOriginal != result.originalUri {
                try? storage.delete(relativeURI: oldOriginal)
            }
            if let climbId = updated.climbId {
                replaceWarnsHolds = try !repos.holds.listByClimb(climbId: climbId).isEmpty
            } else {
                replaceWarnsHolds = false
            }
            photo = updated
            lastErrorMessage = nil
            return updated
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Deletes the photo row and its files. Files go first, best effort: if a file
    /// delete fails the row delete still runs and the launch sweep reconciles the
    /// leftovers, so no orphan row survives. No-op when no photo is loaded.
    public func deletePhoto() throws {
        do {
            guard let current = photo else { return }
            try? storage.deletePhotoFiles(photo: current)
            try repos.media.deletePhoto(id: current.id)
            photo = nil
            replaceWarnsHolds = false
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Internals

    /// Runs the ingest pipeline off the main actor (the decode and re-encode are the
    /// app's heaviest work; only Sendable values cross the boundary).
    private func runIngest(_ request: PhotoIngestRequest) async throws -> PhotoIngestResult {
        let storage = storage
        return try await Task.detached(priority: .userInitiated) {
            try ingestPhoto(request, into: storage)
        }.value
    }

    /// The retention preference at operation time, defaulting to keep originals (the
    /// documented default behind settingsKeyPhotoRetention).
    private func currentRetention() -> PhotoRetentionPreference {
        guard
            let raw = try? repos.settings.getJSON(key: settingsKeyPhotoRetention, as: String.self),
            let preference = PhotoRetentionPreference(rawValue: raw)
        else {
            return .keepOriginals
        }
        return preference
    }
}
