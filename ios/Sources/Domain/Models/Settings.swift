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

// M2 preferences (docs/decisions.md, storage root and quick-log note). Settings rows
// are free-form JSON strings, so these keys ride the existing settings table with no
// change to the export table set or the golden fixtures.
public let settingsKeyAppearance = "ui.appearance"
public let settingsKeyPhotoRetention = "photo.retention"

/// Stored value of settingsKeyAppearance: follow the system theme or force one.
public enum AppearancePreference: String, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// Stored value of settingsKeyPhotoRetention: keep captured originals (the default)
/// or discard them after tagging (enforcement starts with M3 photo capture).
public enum PhotoRetentionPreference: String, CaseIterable, Sendable {
    case keepOriginals = "keep_originals"
    case discardOriginals = "discard_originals"
}
