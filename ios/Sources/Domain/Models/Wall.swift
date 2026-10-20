import Foundation

/// Wall entity, part of the gym aggregate (port of src/domain/models/wall.ts).
public struct Wall: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let gymId: String
    public var name: String?
    public var angleDeg: Double?
    public var angleLabel: String?
    public var isActive: Bool
    public let createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        gymId: String,
        name: String? = nil,
        angleDeg: Double? = nil,
        angleLabel: String? = nil,
        isActive: Bool = true,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.gymId = gymId
        self.name = name
        self.angleDeg = angleDeg
        self.angleLabel = angleLabel
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public let minAngleDeg: Double = 0
public let maxAngleDeg: Double = 90

/// Shared by walls and climbs; both store a wall angle in degrees, nullable.
/// Port of is_angle_valid in src/domain/models/wall.ts.
public func isValidAngle(_ angleDeg: Double?) -> Bool {
    guard let angleDeg else { return true }
    return angleDeg.isFinite && angleDeg >= minAngleDeg && angleDeg <= maxAngleDeg
}
