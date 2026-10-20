import Foundation

/// Gym entity, the aggregate root for walls and sessions (port of src/domain/models/gym.ts).
/// Storage column note: docs/schema.sql models gym archival as is_archived (0 = active),
/// requirements US-8 uses the same concept.
public struct Gym: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var timezone: String?
    public var isArchived: Bool
    public let createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        timezone: String? = nil,
        isArchived: Bool = false,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.timezone = timezone
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
