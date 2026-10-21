import CyberSendData
import CyberSendDomain
import Foundation

// Media sweep (M3, launch path): reconciles the photos/ tree against the photos table
// (docs/decisions.md, launch runs MediaSweep async after first frame). Rows whose
// working copy is missing are dead (the working copy is the coordinate source image and
// always exists while the photo is live), and files with no referencing row are orphans
// from interrupted writes or deletes. Both sides are reconciled in one pass, so a second
// sweep is a no-op and the launch path stays idempotent.

/// What one sweep removed. Both counts are zero on an already clean install.
public struct MediaSweepReport: Equatable, Sendable {
    /// Photo rows deleted because their working copy file was missing.
    public var deletedRows: Int
    /// Files under photos/ deleted because no row referenced them.
    public var deletedFiles: Int

    public init(deletedRows: Int = 0, deletedFiles: Int = 0) {
        self.deletedRows = deletedRows
        self.deletedFiles = deletedFiles
    }
}

/// Reconciles rows against files. Row deletes run in one repository transaction; file
/// deletes follow best effort through the storage layer. Files referenced by surviving
/// rows are never touched, and an orphan row's thumb and original fall out as orphan
/// files in the same pass.
public func sweep(repos: Repositories, storage: MediaStorage) throws -> MediaSweepReport {
    var report = MediaSweepReport()

    let photos = try repos.media.listAllPhotos()
    let live = photos.filter { storage.fileExists(relativeURI: $0.uri) }
    let orphanRowIDs = photos.filter { !storage.fileExists(relativeURI: $0.uri) }.map(\.id)
    if !orphanRowIDs.isEmpty {
        // One transaction for the row deletes (docs/decisions.md, multi table writes).
        try repos.media.deletePhotos(ids: orphanRowIDs)
        report.deletedRows = orphanRowIDs.count
    }

    var referenced = Set<String>()
    for photo in live {
        referenced.insert(photo.uri)
        if let thumbUri = photo.thumbUri {
            referenced.insert(thumbUri)
        }
        if let originalUri = photo.originalUri {
            referenced.insert(originalUri)
        }
    }

    for uri in try storage.listPhotoFileRelativeURIs() where !referenced.contains(uri) {
        try storage.delete(relativeURI: uri)
        report.deletedFiles += 1
    }
    return report
}
