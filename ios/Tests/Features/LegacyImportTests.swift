import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Import side compatibility with the frozen TypeScript port spec (US-16): a hand
// written data.json in the legacy shape (old column names, grade.schemes settings
// JSON) must always import, landing in the reconciled schema with warnings for every
// translated guess (docs/decisions.md schema reconciliation).

@Suite("Legacy import compatibility")
struct LegacyImportTests {
    @Test("legacy TypeScript data.json imports into the reconciled schema")
    func importsLegacyPayload() throws {
        let test = try makeTestDatabase()
        let legacy = try fixtureString("data_legacy_ts_shape")
        let report = try importPayloadJSON(legacy, on: test.writer)
        #expect(report.schemaVersion == currentSchemaVersion)
        #expect(report.migratedFrom == 1, "the legacy file is version 1 and upgrades through the payload migration")
        #expect(report.restoredRows > 0)

        let dump = try test.repos.dump.dumpAll()

        // gyms.is_active 1 becomes gyms.is_archived 0.
        #expect(dump[.gyms].count == 1)
        #expect(dump[.gyms][0]["is_archived"] == .integer(0))

        // climbs: grade_system plus grade_raw become the (scheme id, level id) pair.
        #expect(dump[.climbs].count == 3)
        let byID = Dictionary(uniqueKeysWithValues: dump[.climbs].compactMap { row in
            row["id"]?.textValue.map { ($0, row) }
        })
        #expect(byID["climb-1"]?["grade_system_id"] == .text("v_scale"))
        #expect(byID["climb-1"]?["grade_level_id"] == .text("v4"))
        #expect(byID["climb-1"]?["color_circuit"] == .text("blue"))

        // holds: label becomes role only for valid roles, color becomes color_family.
        let holdsByID = Dictionary(uniqueKeysWithValues: dump[.holds].compactMap { row in
            row["id"]?.textValue.map { ($0, row) }
        })
        #expect(holdsByID["hold-1"]?["role"] == .text("start"))
        #expect(holdsByID["hold-1"]?["color_family"] == .text("blue"))
        #expect(holdsByID["hold-2"]?["role"] == .null, "'jib' is not a valid role")
        #expect(holdsByID["hold-2"]?["color_family"] == .text("red"))

        // M3 payload migration from 1: every translated hold gains a climb_holds
        // membership row keyed by its legacy climb_id, ordinal carried as sequence.
        #expect(dump[.climbHolds].count == 2)
        let membership = Dictionary(uniqueKeysWithValues: dump[.climbHolds].map { row in
            (row["hold_id"]?.textValue ?? "", row)
        })
        #expect(membership["hold-1"]?["climb_id"] == .text("climb-1"))
        #expect(membership["hold-1"]?["sequence"] == .integer(1))
        #expect(membership["hold-2"]?["climb_id"] == .text("climb-1"))
        #expect(membership["hold-2"]?["sequence"] == .integer(2))
        #expect(try test.repos.holds.idsLinkedToClimb(climbId: "climb-1") == ["hold-1", "hold-2"])

        // The legacy photos table is empty, but the original_uri column still exists
        // on every imported row as null.
        #expect(dump[.photos].isEmpty)

        // attempts: fell_on_hold_id becomes fall_on_hold_id, created_at becomes
        // attempted_at.
        #expect(dump[.attempts].count == 1)
        #expect(dump[.attempts][0]["attempted_at"] == .text("2026-01-01T10:00:00.000Z"))
        #expect(dump[.attempts][0]["fall_on_hold_id"] == .null)

        // The grade.schemes settings row converted into grade_systems and grade_levels
        // rows and is gone; every other settings key survives untouched.
        let settingsKeys = Set(dump[.settings].compactMap { $0["key"]?.textValue })
        #expect(settingsKeys == ["gym.default_id"])
        #expect(dump[.gradeSystems].contains { $0["id"] == .text("kilter_soft") && $0["is_builtin"] == .integer(0) })
        #expect(byID["climb-2"]?["grade_system_id"] == .text("kilter_soft"))
        #expect(byID["climb-2"]?["grade_level_id"] == .text("kilter_soft_l1"))
        let levelIDs = Set(dump[.gradeLevels].compactMap { $0["id"]?.textValue })
        #expect(levelIDs.isSuperset(of: ["kilter_soft_l0", "kilter_soft_l1", "kilter_soft_l2"]))

        // Unknown scheme falls back to the default V scale with a warning; unresolvable
        // level drops to null with a warning; the bad hold label warns; the scheme
        // conversion warns.
        #expect(byID["climb-3"]?["grade_system_id"] == .text(defaultGradeSystemID))
        #expect(byID["climb-3"]?["grade_level_id"] == .null)
        #expect(report.warnings.count == 4)
        #expect(report.warnings.contains { $0.contains("moonboard_2019") })
        #expect(report.warnings.contains { $0.contains("kb6") })
        #expect(report.warnings.contains { $0.contains("jib") })
        #expect(report.warnings.contains { $0.contains("custom grade schemes") })
    }

    @Test("legacy re-import is idempotent too (US-16.4)")
    func legacyReimportIsIdempotent() throws {
        let test = try makeTestDatabase()
        let legacy = try fixtureString("data_legacy_ts_shape")
        _ = try importPayloadJSON(legacy, on: test.writer)
        let afterFirst = try test.repos.dump.dumpAll()

        let second = try importPayloadJSON(legacy, on: test.writer)
        #expect(second.restoredRows == 0)
        #expect(second.upserts[.gradeSystems]?.updated == 1)
        #expect(try test.repos.dump.dumpAll() == afterFirst)
        #expect(try rowCount(test.writer, table: .climbs) == 3)
        #expect(try rowCount(test.writer, table: .gradeLevels) == 47, "44 built-ins plus 3 converted custom levels")
    }

    @Test("a legacy export from this app round trips into native shape exports")
    func legacyImportThenNativeExport() throws {
        let test = try makeTestDatabase()
        let legacy = try fixtureString("data_legacy_ts_shape")
        _ = try importPayloadJSON(legacy, on: test.writer)

        let native = try buildExportJSON(repos: test.repos, now: fixtureExportTime)
        let reparsed = try parseExportPayload(native)
        #expect(reparsed.legacyShape == false)
        #expect(reparsed.warnings.isEmpty)
        #expect(reparsed.tables[.climbs]?.count == 3)
    }

    @Test("a legacy payload with a corrupt grade.schemes row still imports")
    func corruptCustomSchemesDegradeToWarning() throws {
        let test = try makeTestDatabase()
        let legacy = try fixtureString("data_legacy_ts_shape")
        let corrupt = legacy.replacingOccurrences(
            of: "[{\\\"id\\\": \\\"kilter_soft\\\"",
            with: "not-a-json-list-{\\\"id\\\": \\\"kilter_soft\\\""
        )
        // Climb 2 referenced the custom scheme, which now cannot resolve: it falls back
        // to the default scheme with a warning instead of failing the import.
        let report = try importPayloadJSON(corrupt, on: test.writer)
        #expect(report.warnings.contains { $0.contains("not valid") })
        #expect(try rowCount(test.writer, table: .climbs) == 3)
        #expect(try rowCount(test.writer, table: .gradeSystems) == 2, "only the built-ins")
    }

    @Test("a legacy scheme id colliding with a built-in never overwrites the built-in")
    func legacySchemeIdCollisionKeepsBuiltins() throws {
        let test = try makeTestDatabase()
        let crafted = try legacyWithCustomSchemes(
            "[{\\\"id\\\": \\\"v_scale\\\", \\\"name\\\": \\\"Fake V Scale\\\", \\\"levels\\\": [{\\\"id\\\": \\\"v0\\\", \\\"label\\\": \\\"MEGA\\\"}]}]"
        )
        let report = try importPayloadJSON(crafted, on: test.writer)
        #expect(report.restoredRows > 0, "the import still succeeds")
        #expect(report.warnings.contains {
            $0.contains("v_scale") && $0.contains("v_scale_imported") && $0.contains("built-in")
        })

        let dump = try test.repos.dump.dumpAll()
        let systems = dump[.gradeSystems] ?? []
        let vScale = systems.first { $0["id"] == .text("v_scale") }
        #expect(vScale?["is_builtin"] == .integer(1), "the built-in row keeps is_builtin")
        #expect(vScale?["name"] == .text("V Scale"), "the built-in name stays")
        #expect(systems.count == 3, "two built-ins plus the renamed import")
        let renamed = systems.first { $0["id"] == .text("v_scale_imported") }
        #expect(renamed?["is_builtin"] == .integer(0))
        #expect(renamed?["name"] == .text("Fake V Scale"))

        // Every built-in level row keeps its label and owning scheme.
        let levels = dump[.gradeLevels] ?? []
        for system in builtinGradeSystems {
            for level in system.levels {
                let row = levels.first { $0["id"] == .text(level.id) }
                #expect(row?["label"] == .text(level.label), "built-in level \(level.id) kept its label")
                #expect(row?["system_id"] == .text(system.id), "built-in level \(level.id) kept its scheme")
            }
        }
        #expect(
            levels.filter { builtinGradeLevelIDs.contains($0["id"]?.textValue ?? "") }.count == builtinGradeLevelIDs.count,
            "no built-in level row was displaced"
        )
        #expect(try rowCount(test.writer, table: .gradeLevels) == 45, "44 built-ins plus the renamed custom level")

        // The colliding level id from the file imported under the renamed scheme.
        let importedLevel = levels.first { $0["id"] == .text("v0_imported") }
        #expect(importedLevel?["label"] == .text("MEGA"))
        #expect(importedLevel?["system_id"] == .text("v_scale_imported"))

        // Climbs still resolve against the untouched built-in scheme, while the scheme
        // this crafted file dropped (kilter_soft) falls back with a warning.
        let climbs = Dictionary(uniqueKeysWithValues: (dump[.climbs] ?? []).compactMap { row in
            row["id"]?.textValue.map { ($0, row) }
        })
        #expect(climbs["climb-1"]?["grade_system_id"] == .text("v_scale"))
        #expect(climbs["climb-1"]?["grade_level_id"] == .text("v4"))
        #expect(climbs["climb-2"]?["grade_system_id"] == .text(defaultGradeSystemID))
        #expect(report.warnings.contains { $0.contains("kilter_soft") })
    }

    @Test("a legacy level id colliding with a built-in never overwrites the built-in level")
    func legacyLevelIdCollisionKeepsBuiltins() throws {
        let test = try makeTestDatabase()
        let crafted = try legacyWithCustomSchemes(
            "[{\\\"id\\\": \\\"kilter_soft\\\", \\\"name\\\": \\\"Kilter Soft\\\", \\\"levels\\\": [{\\\"id\\\": \\\"kilter_soft_l0\\\", \\\"label\\\": \\\"KB1\\\"}, {\\\"id\\\": \\\"kilter_soft_l1\\\", \\\"label\\\": \\\"KB2\\\"}, {\\\"id\\\": \\\"kilter_soft_l2\\\", \\\"label\\\": \\\"KB3\\\"}, {\\\"id\\\": \\\"v4\\\", \\\"label\\\": \\\"Hacked\\\"}]}]"
        )
        let report = try importPayloadJSON(crafted, on: test.writer)
        #expect(report.restoredRows > 0, "the import still succeeds")
        #expect(report.warnings.contains {
            $0.contains("v4") && $0.contains("v4_imported") && $0.contains("built-in")
        })

        let dump = try test.repos.dump.dumpAll()
        let levels = dump[.gradeLevels] ?? []
        let v4 = levels.first { $0["id"] == .text("v4") }
        #expect(v4?["label"] == .text("V4"), "the built-in V4 label stays")
        #expect(v4?["system_id"] == .text("v_scale"))
        let renamed = levels.first { $0["id"] == .text("v4_imported") }
        #expect(renamed?["label"] == .text("Hacked"))
        #expect(renamed?["system_id"] == .text("kilter_soft"))
        #expect(levels.count == 48, "44 built-ins plus 4 custom levels (one renamed)")

        let systems = dump[.gradeSystems] ?? []
        let vScale = systems.first { $0["id"] == .text("v_scale") }
        #expect(vScale?["is_builtin"] == .integer(1), "the built-in row keeps is_builtin")
        #expect(vScale?["name"] == .text("V Scale"), "the built-in name stays")
        let kilter = systems.first { $0["id"] == .text("kilter_soft") }
        #expect(kilter?["is_builtin"] == .integer(0))
        #expect(kilter?["name"] == .text("Kilter Soft"))

        // The custom scheme's untouched levels and its climb keep resolving normally.
        let climbs = Dictionary(uniqueKeysWithValues: (dump[.climbs] ?? []).compactMap { row in
            row["id"]?.textValue.map { ($0, row) }
        })
        #expect(climbs["climb-2"]?["grade_system_id"] == .text("kilter_soft"))
        #expect(climbs["climb-2"]?["grade_level_id"] == .text("kilter_soft_l1"))
    }

    /// Rewrites the fixture's grade.schemes settings JSON (escaped inside the JSON
    /// string) with a crafted list of custom schemes.
    private func legacyWithCustomSchemes(_ schemes: String) throws -> String {
        let legacy = try fixtureString("data_legacy_ts_shape")
        let original = "[{\\\"id\\\": \\\"kilter_soft\\\", \\\"name\\\": \\\"Kilter Soft\\\", \\\"levels\\\": [{\\\"id\\\": \\\"kilter_soft_l0\\\", \\\"label\\\": \\\"KB1\\\"}, {\\\"id\\\": \\\"kilter_soft_l1\\\", \\\"label\\\": \\\"KB2\\\"}, {\\\"id\\\": \\\"kilter_soft_l2\\\", \\\"label\\\": \\\"KB3\\\"}]}]"
        #expect(legacy.contains(original), "the fixture's grade.schemes row changed shape")
        return legacy.replacingOccurrences(of: original, with: schemes)
    }
}
