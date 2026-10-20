import Foundation

/// Settings entity (port of src/domain/models/settings.ts). Values are stored as JSON text in
/// the settings table (key, value_json).
public struct SettingEntry: Codable, Equatable, Sendable {
    public let key: String
    public var valueJson: String
    public var updatedAt: String

    public init(key: String, valueJson: String, updatedAt: String) {
        self.key = key
        self.valueJson = valueJson
        self.updatedAt = updatedAt
    }
}

// Keys shared across layers. grade.schemes is gone after the schema reconciliation: custom
// schemes are grade_systems and grade_levels rows now (US-9 normalized storage).
public let settingsKeyFlagOverrides = "flags.override"
public let settingsKeyDefaultGymID = "gym.default_id"
public let settingsKeyDefaultGradeSystem = "grade.default_scheme"
public let settingsKeyLastBackupAt = "backup.last_automatic_at"
