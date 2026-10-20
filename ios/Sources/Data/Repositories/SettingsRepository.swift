import CyberSendDomain
import Foundation
import GRDB

// Settings repository (port of src/data/repositories/settings_repository.ts). Values are JSON
// text; keys are stable identifiers from Sources/Domain/Models/Settings.swift.

public protocol SettingsRepository: Sendable {
    func get(key: String) throws -> String?
    /// Decodes the stored JSON value, or nil when the key is absent. Throws settings_corrupt
    /// when the stored text is not valid JSON.
    func getJSON<T: Decodable>(key: String, as type: T.Type) throws -> T?
    func set(key: String, valueJson: String) throws
    func setJSON(key: String, value: some Encodable) throws
    func remove(key: String) throws
    func list() throws -> [SettingEntry]
}

public struct GRDBSettingsRepository: SettingsRepository {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func get(key: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value_json FROM settings WHERE key = ?", arguments: [key])
        }
    }

    public func getJSON<T: Decodable>(key: String, as type: T.Type) throws -> T? {
        guard let raw = try get(key: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(raw.utf8))
        } catch {
            throw DomainValidationError("settings_corrupt", "Stored value for \(key) is not valid JSON.")
        }
    }

    public func set(key: String, valueJson: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at
                """,
                arguments: [key, valueJson, nowISO8601()]
            )
        }
    }

    public func setJSON(key: String, value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DomainValidationError("settings_corrupt", "Value for \(key) could not be encoded as JSON.")
        }
        try set(key: key, valueJson: json)
    }

    public func remove(key: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
        }
    }

    public func list() throws -> [SettingEntry] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT key, value_json, updated_at FROM settings ORDER BY key").map { row in
                SettingEntry(key: row["key"], valueJson: row["value_json"], updatedAt: row["updated_at"])
            }
        }
    }
}
