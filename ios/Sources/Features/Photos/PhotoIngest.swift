import CoreGraphics
import CyberSendData
import CyberSendDomain
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Photo ingest pipeline (M3, US-17): bytes in, working copy and thumbnail out, with the
// retained original written per the photo retention preference. ImageIO thumbnails with
// kCGImageSourceCreateThumbnailWithTransform bake the EXIF orientation into the pixels,
// so the 2048 px working copy is the single pixels up coordinate source for the tagging
// canvas (docs/decisions.md "photo capture is PhotosPicker plus UIImagePickerController
// behind a seam"). Decoding happens before any file is written and a failed write rolls
// the others back, so a failed ingest leaves zero partial files.

/// Long edge of the working copy, the coordinate source image (US-17.4, 2048 policy).
public let photoIngestWorkingLongEdge: CGFloat = 2048
/// Long edge of the thumbnail used in lists and fall hold sheets.
public let photoIngestThumbLongEdge: CGFloat = 256
/// JPEG quality for the working copy, thumbnail, and the camera original re-encode.
public let photoIngestJPEGQuality: Double = 0.85
/// Sources above this size surface a warning in the ingest result so the UI can notice
/// (US-17; the ingest itself still succeeds).
public let photoIngestLargeSourceBytes = 30 * 1024 * 1024

/// Plain ingest failure shape, mirroring the DomainValidationError code plus message
/// convention so screens get one error presentation path.
public struct PhotoIngestError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
}

extension PhotoIngestError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Everything one ingest needs. Sendable so the decode runs off the main actor.
public struct PhotoIngestRequest: Equatable, Sendable {
    /// The photo id (a repository generated UUID); file names derive from it.
    public var photoID: String
    public var bytes: Data
    public var source: PhotoSource
    public var capturedAt: String
    public var retention: PhotoRetentionPreference
    public var climbId: String?
    public var sessionId: String?

    public init(
        photoID: String,
        bytes: Data,
        source: PhotoSource,
        capturedAt: String,
        retention: PhotoRetentionPreference,
        climbId: String? = nil,
        sessionId: String? = nil
    ) {
        self.photoID = photoID
        self.bytes = bytes
        self.source = source
        self.capturedAt = capturedAt
        self.retention = retention
        self.climbId = climbId
        self.sessionId = sessionId
    }
}

/// The files an ingest wrote plus the values the photo row needs. No database access
/// happens here; the store turns this into a CreatePhotoInput.
public struct PhotoIngestResult: Equatable, Sendable {
    public var photoID: String
    public var workingUri: String
    public var thumbUri: String
    /// Set only when retention keeps originals.
    public var originalUri: String?
    /// Working copy pixel dimensions, after the orientation bake.
    public var width: Int
    public var height: Int
    public var source: PhotoSource
    public var capturedAt: String
    public var climbId: String?
    public var sessionId: String?
    /// True when the source exceeded photoIngestLargeSourceBytes; the UI may show a
    /// notice while the ingest itself succeeded.
    public var warnsLargeSource: Bool

    public init(
        photoID: String,
        workingUri: String,
        thumbUri: String,
        originalUri: String?,
        width: Int,
        height: Int,
        source: PhotoSource,
        capturedAt: String,
        climbId: String?,
        sessionId: String?,
        warnsLargeSource: Bool
    ) {
        self.photoID = photoID
        self.workingUri = workingUri
        self.thumbUri = thumbUri
        self.originalUri = originalUri
        self.width = width
        self.height = height
        self.source = source
        self.capturedAt = capturedAt
        self.climbId = climbId
        self.sessionId = sessionId
        self.warnsLargeSource = warnsLargeSource
    }
}

/// Decodes the source once into the 2048 px working copy and 256 px thumbnail, writes
/// them plus the retention dependent original, and returns the stored uris and working
/// dimensions. One ingest at a time by design (the camera original re-encode is the
/// app's largest memory spike, mitigated by the autoreleasepool and by the retention
/// aware path that never decodes full resolution when originals are discarded).
public func ingestPhoto(_ request: PhotoIngestRequest, into storage: MediaStorage) throws -> PhotoIngestResult {
    guard !request.bytes.isEmpty else {
        throw PhotoIngestError("ingest_empty_source", "The photo has no data to import.")
    }

    let decoded: DecodedIngest = try autoreleasepool {
        guard let source = CGImageSourceCreateWithData(request.bytes as CFData, nil) else {
            throw PhotoIngestError("ingest_decode_failed", "The photo could not be decoded.")
        }
        guard
            let working = makeThumbnail(from: source, maxPixelSize: photoIngestWorkingLongEdge),
            let thumb = makeThumbnail(from: source, maxPixelSize: photoIngestThumbLongEdge)
        else {
            throw PhotoIngestError("ingest_decode_failed", "The photo could not be decoded.")
        }
        let workingJPEG = try jpegData(working, quality: photoIngestJPEGQuality)
        let thumbJPEG = try jpegData(thumb, quality: photoIngestJPEGQuality)
        let original = try retainedOriginalBytes(request: request, source: source, working: working)
        return DecodedIngest(
            workingJPEG: workingJPEG,
            thumbJPEG: thumbJPEG,
            width: working.width,
            height: working.height,
            original: original
        )
    }

    var workingUri = ""
    var thumbUri = ""
    var originalUri: String?
    do {
        workingUri = try storage.writeWorking(decoded.workingJPEG, photoID: request.photoID)
        thumbUri = try storage.writeThumb(decoded.thumbJPEG, photoID: request.photoID)
        if let original = decoded.original {
            originalUri = try storage.writeOriginal(
                original.bytes,
                photoID: request.photoID,
                fileExtension: original.fileExtension
            )
        }
    } catch {
        // Zero partial files on failure: roll back whatever this ingest wrote.
        for uri in [workingUri, thumbUri, originalUri].compactMap({ $0 }) {
            try? storage.delete(relativeURI: uri)
        }
        throw error
    }

    return PhotoIngestResult(
        photoID: request.photoID,
        workingUri: workingUri,
        thumbUri: thumbUri,
        originalUri: originalUri,
        width: decoded.width,
        height: decoded.height,
        source: request.source,
        capturedAt: request.capturedAt,
        climbId: request.climbId,
        sessionId: request.sessionId,
        warnsLargeSource: request.bytes.count > photoIngestLargeSourceBytes
    )
}

/// Tagging save path (M3 retention): deletes the retained original file for a photo and
/// clears original_uri on its row, returning the updated value. Called when the
/// preference is discard originals and the photo was captured while it kept them (the
/// original was written at ingest, then discarded here at tagging save).
@discardableResult
public func discardOriginal(
    into storage: MediaStorage,
    photo: Photo,
    media: any MediaRepository
) throws -> Photo {
    if let originalUri = photo.originalUri {
        try storage.delete(relativeURI: originalUri)
    }
    _ = try media.updatePhoto(id: photo.id, patch: UpdatePhotoPatch(originalUri: .set(nil)))
    var updated = photo
    updated.originalUri = nil
    return updated
}

// MARK: - Internals

private struct DecodedIngest {
    var workingJPEG: Data
    var thumbJPEG: Data
    var width: Int
    var height: Int
    /// Retained original bytes and the file extension for its stored uri.
    var original: (bytes: Data, fileExtension: String)?
}

/// The ImageIO thumbnail options that bake orientation into pixels (the transform) and
/// force a full quality decode at the requested long edge.
private func thumbnailOptions(maxPixelSize: CGFloat) -> [CFString: Any] {
    [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
}

private func makeThumbnail(from source: CGImageSource, maxPixelSize: CGFloat) -> CGImage? {
    CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(maxPixelSize: maxPixelSize) as CFDictionary)
}

private func jpegData(_ image: CGImage, quality: Double) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        throw PhotoIngestError("ingest_encode_failed", "The photo could not be encoded.")
    }
    CGImageDestinationAddImage(destination, image, [
        kCGImageDestinationLossyCompressionQuality: quality
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw PhotoIngestError("ingest_encode_failed", "The photo could not be encoded.")
    }
    return data as Data
}

/// The retained original per the preference. Keep originals: the camera path re-encodes
/// the full resolution pixels up inside the caller's autoreleasepool (the largest memory
/// spike in the app, only reachable when retention keeps), while the library path stores
/// the picker bytes verbatim with the source container extension. Discard originals
/// skips the full resolution decode entirely at ingest.
private func retainedOriginalBytes(
    request: PhotoIngestRequest,
    source: CGImageSource,
    working: CGImage
) throws -> (bytes: Data, fileExtension: String)? {
    switch request.retention {
    case .discardOriginals:
        return nil
    case .keepOriginals:
        switch request.source {
        case .camera:
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? working.width
            let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? working.height
            let longEdge = max(pixelWidth, pixelHeight)
            guard longEdge > 0,
                  let fullResolution = makeThumbnail(from: source, maxPixelSize: CGFloat(longEdge))
            else {
                throw PhotoIngestError("ingest_decode_failed", "The photo could not be decoded.")
            }
            return (try jpegData(fullResolution, quality: photoIngestJPEGQuality), "jpg")
        case .library:
            return (request.bytes, sourceFileExtension(source))
        }
    }
}

/// The stored original extension for verbatim library bytes, from the source container
/// type (jpg, png, heic, and so on). The JPEG family normalizes to "jpg" so a library
/// JPEG lands on the same extension the camera path writes.
private func sourceFileExtension(_ source: CGImageSource) -> String {
    guard
        let type = CGImageSourceGetType(source) as String?,
        let utType = UTType(type),
        let ext = utType.preferredFilenameExtension,
        !ext.isEmpty
    else {
        return "dat"
    }
    let lowered = ext.lowercased()
    return lowered == "jpeg" ? "jpg" : lowered
}
