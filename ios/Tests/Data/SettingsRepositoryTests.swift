import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain

// Settings repository tests: JSON text storage, upsert semantics, corrupt value handling.

@Suite("SettingsRepository")
struct SettingsRepositoryTests {
    @Test("set, get, and remove a value")
    func setGetRemove() throws {
        let test = try makeTestDatabase()
        #expect(try test.repos.settings.get(key: "missing") == nil)

        try test.repos.settings.set(key: "gym.default_id", valueJson: "\"abc\"")
        #expect(try test.repos.settings.get(key: "gym.default_id") == "\"abc\"")

        // Setting again upserts.
        try test.repos.settings.set(key: "gym.default_id", valueJson: "\"def\"")
        #expect(try test.repos.settings.get(key: "gym.default_id") == "\"def\"")

        try test.repos.settings.remove(key: "gym.default_id")
        #expect(try test.repos.settings.get(key: "gym.default_id") == nil)
    }

    @Test("typed JSON round trips through Codable values")
    func typedJSONRoundTrip() throws {
        let test = try makeTestDatabase()
        try test.repos.settings.setJSON(key: "flags.override", value: ["ai_hold_detection": true])
        let decoded = try test.repos.settings.getJSON(key: "flags.override", as: [String: Bool].self)
        #expect(decoded == ["ai_hold_detection": true])
    }

    @Test("corrupt stored JSON throws settings_corrupt")
    func corruptJSONThrows() throws {
        let test = try makeTestDatabase()
        try test.repos.settings.set(key: "flags.override", valueJson: "not json")
        #expect(try test.repos.settings.get(key: "flags.override") == "not json")

        let error = #expect(throws: DomainValidationError.self) {
            try test.repos.settings.getJSON(key: "flags.override", as: [String: Bool].self)
        }
        #expect(error?.code == "settings_corrupt")
    }

    @Test("list returns entries ordered by key")
    func listsOrderedByKey() throws {
        let test = try makeTestDatabase()
        try test.repos.settings.set(key: "b", valueJson: "2")
        try test.repos.settings.set(key: "a", valueJson: "1")

        let entries = try test.repos.settings.list()
        #expect(entries.map(\.key) == ["a", "b"])
        #expect(entries.first?.valueJson == "1")
    }
}
