import Foundation

/// Hold source enum (port of src/domain/models/hold.ts).
public enum HoldSource: String, Codable, CaseIterable, Sendable {
    case manual
    case detection
    case board
}

/// Hold role enum (requirements US-19: start, intermediate, top; schema reconciliation
/// renamed the old free-text holds.label column to holds.role). Nil means unassigned.
public enum HoldRole: String, Codable, CaseIterable, Sendable {
    case start
    case intermediate
    case top
}

/// Hold entity. Coordinates are normalized 0..1 over the source image; radiusNorm is relative
/// to image width (docs/decisions.md 2026-10-19, normalized coordinates).
public struct Hold: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let climbId: String
    public var xNorm: Double
    public var yNorm: Double
    public var radiusNorm: Double
    public var role: HoldRole?
    public var colorFamily: String?
    public var source: HoldSource
    public var ordinal: Int?
    public let createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        climbId: String,
        xNorm: Double,
        yNorm: Double,
        radiusNorm: Double,
        role: HoldRole? = nil,
        colorFamily: String? = nil,
        source: HoldSource = .manual,
        ordinal: Int? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.climbId = climbId
        self.xNorm = xNorm
        self.yNorm = yNorm
        self.radiusNorm = radiusNorm
        self.role = role
        self.colorFamily = colorFamily
        self.source = source
        self.ordinal = ordinal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public let holdSources: [HoldSource] = [.manual, .detection, .board]

/// Validates normalized hold coordinates before any write (domain boundary rule).
/// Port of validate_hold_coords in src/domain/models/hold.ts.
public func validateHoldCoords(xNorm: Double, yNorm: Double, radiusNorm: Double) throws {
    guard xNorm.isFinite, xNorm >= 0, xNorm <= 1 else {
        throw DomainValidationError("hold_x_out_of_range", "Hold x coordinate must be within 0 to 1.")
    }
    guard yNorm.isFinite, yNorm >= 0, yNorm <= 1 else {
        throw DomainValidationError("hold_y_out_of_range", "Hold y coordinate must be within 0 to 1.")
    }
    guard radiusNorm.isFinite, radiusNorm > 0 else {
        throw DomainValidationError("hold_radius_invalid", "Hold radius must be greater than 0.")
    }
}
