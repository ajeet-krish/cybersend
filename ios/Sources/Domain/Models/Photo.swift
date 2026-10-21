import Foundation

/// Photo entity (port of src/domain/models/photo.ts). Media uris are relative to the app
/// document root for portability. Capture and tagging flows arrive in phase 2.
public enum PhotoSource: String, Codable, CaseIterable, Sendable {
    case camera
    case library
}

public let photoSources: [PhotoSource] = [.camera, .library]

public struct Photo: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var climbId: String?
    public var sessionId: String?
    public var uri: String
    public var thumbUri: String?
    /// The retained full resolution original (M3): written when the photo retention
    /// preference keeps originals, nil otherwise (tagging save discards it at save when
    /// the preference is discard).
    public var originalUri: String?
    public var width: Int
    public var height: Int
    public var source: PhotoSource
    public var capturedAt: String
    public let createdAt: String

    public init(
        id: String,
        climbId: String? = nil,
        sessionId: String? = nil,
        uri: String,
        thumbUri: String? = nil,
        originalUri: String? = nil,
        width: Int,
        height: Int,
        source: PhotoSource = .camera,
        capturedAt: String,
        createdAt: String
    ) {
        self.id = id
        self.climbId = climbId
        self.sessionId = sessionId
        self.uri = uri
        self.thumbUri = thumbUri
        self.originalUri = originalUri
        self.width = width
        self.height = height
        self.source = source
        self.capturedAt = capturedAt
        self.createdAt = createdAt
    }
}
