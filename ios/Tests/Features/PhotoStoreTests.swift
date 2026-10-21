import Foundation
import GRDB
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Photo store tests (M3, US-17 and US-20.2): one photo per climb, ingest off the main
// actor over the identical pipeline, replace warning when the climb already has holds,
// retention enforcement, and the delete path that removes row plus files.

@Suite("PhotoStore")
@MainActor
struct PhotoStoreTests {
    private func makeStore() throws -> (store: PhotoStore, repos: Repositories, storage: MediaStorage, climbId: String) {
        let test = try makeTestDatabase()
        let (_, climbId) = try seedGymAndClimb(test.repos)
        let storage = MediaStorage(root: try makeTempMediaRoot())
        return (PhotoStore(repos: test.repos, storage: storage), test.repos, storage, climbId)
    }

    @Test("addPhoto ingests, creates the row, and a second add on the climb is rejected")
    func addPhotoCreatesRowAndRejectsDuplicates() async throws {
        let (store, repos, storage, climbId) = try makeStore()

        let bytes = try makeQuadrantJPEG(width: 640, height: 480)
        let photo = try await store.addPhoto(bytes: bytes, source: .camera, climbId: climbId, sessionId: nil)

        #expect(store.photo == photo)
        #expect(store.lastErrorMessage == nil)
        #expect(store.replaceWarnsHolds == false)
        #expect(photo.climbId == climbId)
        #expect(photo.width == 640)
        #expect(photo.height == 480)
        #expect(photo.originalUri != nil, "the default retention keeps originals")
        #expect(try repos.media.getPhoto(id: photo.id) == photo)
        #expect(storage.fileExists(relativeURI: photo.uri))
        #expect(storage.fileExists(relativeURI: try #require(photo.thumbUri)))

        // US-20.2: one photo per climb. The duplicate attempt writes nothing.
        let error = await #expect(throws: DomainValidationError.self) {
            try await store.addPhoto(bytes: bytes, source: .library, climbId: climbId)
        }
        #expect(error?.code == "photo_already_exists")
        #expect(try repos.media.listPhotos(filter: ListPhotosFilter(climbId: climbId)).count == 1)
        #expect(try storage.listPhotoFileRelativeURIs().count == 3)
        #expect(store.lastErrorMessage?.contains("already has a photo") == true)
    }

    @Test("discard retention skips the original and load picks the climb photo")
    func discardRetentionAndLoad() async throws {
        let (store, repos, storage, climbId) = try makeStore()
        try repos.settings.setJSON(key: settingsKeyPhotoRetention, value: PhotoRetentionPreference.discardOriginals.rawValue)

        let bytes = try makeQuadrantJPEG(width: 640, height: 480)
        let photo = try await store.addPhoto(bytes: bytes, source: .camera, climbId: climbId)

        #expect(photo.originalUri == nil)
        #expect(try storage.listPhotoFileRelativeURIs().count == 2)

        // A fresh store over the same repositories loads the same photo.
        let fresh = PhotoStore(repos: repos, storage: storage)
        fresh.load(climbId: climbId)
        #expect(fresh.photo == photo)
        #expect(fresh.lastErrorMessage == nil)

        // A climb without a photo loads nil.
        let (_, otherClimbId) = try seedGymAndClimb2(repos)
        fresh.load(climbId: otherClimbId)
        #expect(fresh.photo == nil)
    }

    @Test("replacePhoto updates in place, warns about holds, and honors a retention change")
    func replaceWarnsHolds() async throws {
        let (store, repos, storage, climbId) = try makeStore()
        let bytes = try makeQuadrantJPEG(width: 640, height: 480)
        let original = try await store.addPhoto(bytes: bytes, source: .camera, climbId: climbId)

        // No holds yet: a replace has nothing to warn about.
        let firstReplace = try await store.replacePhoto(bytes: try makeQuadrantJPEG(width: 320, height: 240), source: .library)
        #expect(store.replaceWarnsHolds == false)
        #expect(firstReplace.id == original.id, "replace keeps the identity")
        #expect(firstReplace.width == 320)
        #expect(firstReplace.height == 240)
        #expect(try repos.media.getPhoto(id: original.id)?.width == 320)

        // Holds appear, the retention flips to discard, and the replace warns while
        // dropping the previously retained original file.
        _ = try repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 0.5, yNorm: 0.5))
        let oldOriginal = try #require(original.originalUri)
        #expect(storage.fileExists(relativeURI: oldOriginal))
        try repos.settings.setJSON(key: settingsKeyPhotoRetention, value: PhotoRetentionPreference.discardOriginals.rawValue)

        let secondReplace = try await store.replacePhoto(bytes: try makeQuadrantJPEG(width: 500, height: 400), source: .camera)
        #expect(store.replaceWarnsHolds == true, "the climb has holds tuned to the old image")
        #expect(store.photo == secondReplace)
        #expect(secondReplace.originalUri == nil, "the new retention discards")
        #expect(!storage.fileExists(relativeURI: oldOriginal), "the stale original is deleted")
        #expect(storage.fileExists(relativeURI: secondReplace.uri))
        // Still exactly one photo row for the climb.
        #expect(try repos.media.listPhotos(filter: ListPhotosFilter(climbId: climbId)).count == 1)
    }

    @Test("deletePhoto removes the row and every file, and errors publish lastErrorMessage")
    func deletePhotoAndErrorReporting() async throws {
        let (store, repos, storage, climbId) = try makeStore()

        // Replacing before any photo exists fails with a published message and no state.
        let missing = await #expect(throws: DomainValidationError.self) {
            try await store.replacePhoto(bytes: Data([0x01]), source: .camera)
        }
        #expect(missing?.code == "photo_not_found")
        #expect(store.photo == nil)
        #expect(store.lastErrorMessage != nil)

        let bytes = try makeQuadrantJPEG(width: 640, height: 480)
        let photo = try await store.addPhoto(bytes: bytes, source: .camera, climbId: climbId)
        #expect(try storage.listPhotoFileRelativeURIs().count == 3)

        try store.deletePhoto()

        #expect(store.photo == nil)
        #expect(store.lastErrorMessage == nil)
        #expect(try repos.media.getPhoto(id: photo.id) == nil)
        #expect(try storage.listPhotoFileRelativeURIs().isEmpty)

        // Delete with nothing loaded is a no op, not an error.
        try store.deletePhoto()
    }
}

/// A second gym plus climb pair for the multi climb cases (the shared seed helper is
/// one pair per call site in the Data suite, so this keeps the store suite readable).
private func seedGymAndClimb2(_ repos: Repositories) throws -> (gymId: String, climbId: String) {
    let gym = try repos.gyms.create(CreateGymInput(name: "Second Gym"))
    let climb = try repos.climbs.create(CreateClimbInput(gymId: gym.id, name: "Red V5"))
    return (gym.id, climb.id)
}
