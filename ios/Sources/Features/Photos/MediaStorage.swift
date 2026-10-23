import CyberSendDomain
import Foundation

// Media file storage (M3, US-17): the photos/ tree under the app storage root with three
// directories (working, thumbs, originals). Database rows store relative uri strings such
// as "photos/working/<uuid>.jpg" (docs/decisions.md, storage root is Application
// Support), so backups stay portable and MediaSweep can reconcile files against rows.
// Every path is built from validated components: photo ids are UUIDs and every stored uri
// passes the traversal guard before it becomes a URL on disk.

public enum MediaStorageError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The photo id is not a UUID, so it cannot become a path component.
    case invalidPhotoID(String)
    /// The relative uri is absolute, empty, or traverses out of the storage root.
    case unsafeRelativeURI(String)
    /// A file write failed; the message carries the underlying reason.
    case writeFailed(String)

    public var description: String {
        switch self {
        case .invalidPhotoID(let id):
            return "Invalid photo id: \(id)."
        case .unsafeRelativeURI(let uri):
            return "Unsafe media path: \(uri)."
        case .writeFailed(let reason):
            return "Media write failed: \(reason)."
        }
    }
}

extension MediaStorageError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Sendable file storage over the app storage root. All methods are synchronous and
/// throw MediaStorageError; missing files are not errors for existence checks or
/// deletion, so callers can treat cleanup as best effort.
public struct MediaStorage: Sendable {
    /// The app storage root (Application Support/CyberSend in the app, a temp directory
    /// in tests). Relative uris stored in the database resolve against this root.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var photosDirectory: URL {
        root.appendingPathComponent("photos", isDirectory: true)
    }

    public var workingDirectory: URL {
        photosDirectory.appendingPathComponent("working", isDirectory: true)
    }

    public var thumbsDirectory: URL {
        photosDirectory.appendingPathComponent("thumbs", isDirectory: true)
    }

    public var originalsDirectory: URL {
        photosDirectory.appendingPathComponent("originals", isDirectory: true)
    }

    /// Imported video files (UI overhaul: retroactive session media). Videos are not
    /// re-encoded, so the byte for byte clip the library handed over is what playback reads.
    public var videosDirectory: URL {
        root.appendingPathComponent("videos", isDirectory: true)
    }

    // MARK: - Relative uris

    /// The stored uri of the pixels up working copy ("photos/working/<uuid>.jpg").
    public func workingRelativeURI(photoID: String) throws -> String {
        "photos/working/\(try validatedPhotoID(photoID)).jpg"
    }

    /// The stored uri of the thumbnail ("photos/thumbs/<uuid>.jpg").
    public func thumbRelativeURI(photoID: String) throws -> String {
        "photos/thumbs/\(try validatedPhotoID(photoID)).jpg"
    }

    /// The stored uri of a retained original ("photos/originals/<uuid>.<ext>").
    public func originalRelativeURI(photoID: String, fileExtension: String) throws -> String {
        let ext = fileExtension.lowercased()
        guard !ext.isEmpty, !ext.contains("/"), !ext.contains("..") else {
            throw MediaStorageError.unsafeRelativeURI(fileExtension)
        }
        return "photos/originals/\(try validatedPhotoID(photoID)).\(ext)"
    }

    /// The stored uri of an imported video ("videos/<uuid>.<ext>").
    public func videoRelativeURI(videoID: String, fileExtension: String) throws -> String {
        let ext = fileExtension.lowercased()
        guard !ext.isEmpty, !ext.contains("/"), !ext.contains("..") else {
            throw MediaStorageError.unsafeRelativeURI(fileExtension)
        }
        return "videos/\(try validatedPhotoID(videoID)).\(ext)"
    }

    // MARK: - Writes

    /// Writes the working copy bytes atomically, creating the directory tree as needed.
    /// Returns the stored relative uri.
    @discardableResult
    public func writeWorking(_ bytes: Data, photoID: String) throws -> String {
        let uri = try workingRelativeURI(photoID: photoID)
        try write(bytes, toRelativeURI: uri)
        return uri
    }

    /// Writes the thumbnail bytes atomically. Returns the stored relative uri.
    @discardableResult
    public func writeThumb(_ bytes: Data, photoID: String) throws -> String {
        let uri = try thumbRelativeURI(photoID: photoID)
        try write(bytes, toRelativeURI: uri)
        return uri
    }

    /// Writes an imported video atomically. Returns the stored relative uri.
    @discardableResult
    public func writeVideo(_ bytes: Data, videoID: String, fileExtension: String) throws -> String {
        let uri = try videoRelativeURI(videoID: videoID, fileExtension: fileExtension)
        try write(bytes, toRelativeURI: uri)
        return uri
    }

    /// Adopts a file the capture stack already wrote, usually AVCaptureMovieFileOutput's temp
    /// recording. Moves rather than reads, so a 30 s 1080p60 clip never passes through Data and
    /// never doubles its disk footprint. Returns the stored relative uri.
    @discardableResult
    public func adoptVideo(fileAt source: URL, videoID: String, fileExtension: String) throws -> String {
        let uri = try videoRelativeURI(videoID: videoID, fileExtension: fileExtension)
        let destination = try url(relativeURI: uri)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw MediaStorageError.writeFailed(error.localizedDescription)
        }
        return uri
    }

    /// Writes a retained original atomically. Returns the stored relative uri.
    @discardableResult
    public func writeOriginal(_ bytes: Data, photoID: String, fileExtension: String) throws -> String {
        let uri = try originalRelativeURI(photoID: photoID, fileExtension: fileExtension)
        try write(bytes, toRelativeURI: uri)
        return uri
    }

    // MARK: - Reads

    /// The bytes behind a stored uri, or nil when the file does not exist. Unsafe uris
    /// throw instead of resolving outside the root.
    public func read(relativeURI: String) throws -> Data? {
        let url = try url(relativeURI: relativeURI)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Whether a stored uri points at an existing file. Unsafe uris report false.
    public func fileExists(relativeURI: String) -> Bool {
        guard let url = try? url(relativeURI: relativeURI) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Deletes

    /// Deletes the file behind a stored uri. A missing file is not an error.
    public func delete(relativeURI: String) throws {
        let url = try url(relativeURI: relativeURI)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Removes every file a photo row references (working, thumb, and retained
    /// original). Missing files are ignored, so cleanup is safe after partial writes.
    public func deletePhotoFiles(photo: Photo) throws {
        try delete(relativeURI: photo.uri)
        if let thumbUri = photo.thumbUri {
            try delete(relativeURI: thumbUri)
        }
        if let originalUri = photo.originalUri {
            try delete(relativeURI: originalUri)
        }
    }

    // MARK: - Listing (media sweep input)

    /// Every file under the three photo directories as sorted relative uris. Only flat
    /// files are listed; unexpected subdirectories are skipped, never recursed.
    public func listPhotoFileRelativeURIs() throws -> [String] {
        var uris: [String] = []
        uris.append(contentsOf: try fileListing(in: workingDirectory, prefix: "photos/working"))
        uris.append(contentsOf: try fileListing(in: thumbsDirectory, prefix: "photos/thumbs"))
        uris.append(contentsOf: try fileListing(in: originalsDirectory, prefix: "photos/originals"))
        return uris.sorted()
    }

    // MARK: - URL resolution

    /// Resolves a stored uri to a file URL inside the root, rejecting absolute paths,
    /// empty strings, and traversal (the same guard the backup import uses).
    public func url(relativeURI: String) throws -> URL {
        guard isSafeRelativePath(relativeURI) else {
            throw MediaStorageError.unsafeRelativeURI(relativeURI)
        }
        let url = root.appendingPathComponent(relativeURI).standardizedFileURL
        let rootPrefix = root.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(rootPrefix) else {
            throw MediaStorageError.unsafeRelativeURI(relativeURI)
        }
        return url
    }

    // MARK: - Internals

    /// Photo ids become path components, so they must be UUIDs (the repository id
    /// format); anything else can never reach the file system.
    private func validatedPhotoID(_ photoID: String) throws -> String {
        guard UUID(uuidString: photoID) != nil else {
            throw MediaStorageError.invalidPhotoID(photoID)
        }
        return photoID
    }

    private func write(_ bytes: Data, toRelativeURI relativeURI: String) throws {
        let url = try url(relativeURI: relativeURI)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw MediaStorageError.writeFailed(error.localizedDescription)
        }
    }

    private func fileListing(in directory: URL, prefix: String) throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        return names.compactMap { name in
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(name).path
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }
            return "\(prefix)/\(name)"
        }
    }
}
