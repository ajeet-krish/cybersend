import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Import service (US-16): plain-language version rejection with zero writes, older
// payloads migrated through the injectable registry, corrupt files aborting atomically,
// idempotent re-import keyed on stable ids, and the built-in grade id collision guard
// for native-shape files (the legacy-shape guard lives in LegacyImportTests).

@Suite("Import service")
struct ImportTests {
    @Test("not valid JSON is rejected with zero writes (US-16.3)")
    func rejectsInvalidJSON() throws {
        let test = try makeTestDatabase()
        let error = #expect(throws: ImportPayloadError.self) {
            try importPayloadJSON("{not json", on: test.writer)
        }
        #expect(error?.message == "The file is not valid JSON. Nothing was imported.")
        #expect(try rowCount(test.writer, table: .gyms) == 0)
    }

    @Test("missing tables, unknown columns, and wrong types are rejected (US-16.3)")
    func rejectsMalformedPayloads() throws {
        let test = try makeTestDatabase()
        let valid = gymsPayloadJSON()

        // Missing a table entity entirely.
        let droppedTable = valid.replacingOccurrences(of: "    \"grade_norm_params\": [],\n", with: "")
        #expect(throws: ImportPayloadError.self) {
            try importPayloadJSON(droppedTable, on: test.writer)
        }

        // Wrong app id.
        let wrongApp = valid.replacingOccurrences(of: "\"cybersend\"", with: "\"otherapp\"")
        let appError = #expect(throws: ImportPayloadError.self) {
            try importPayloadJSON(wrongApp, on: test.writer)
        }
        #expect(appError?.message == "The file is not a valid CyberSend export (missing entity, bad value, or bad column). Nothing was imported.")

        // Unknown column smuggled into a row.
        let extraColumn = valid.replacingOccurrences(
            of: "\"is_archived\": 0",
            with: "\"is_archived\": 0, \"evil\": 1"
        )
        let columnError = #expect(throws: ImportPayloadError.self) {
            try importPayloadJSON(extraColumn, on: test.writer)
        }
        #expect(columnError?.message.contains("not a valid CyberSend export") == true)

        // Fractional value on an integer column.
        let fractional = valid.replacingOccurrences(of: "\"is_archived\": 0", with: "\"is_archived\": 0.5")
        #expect(throws: ImportPayloadError.self) {
            try importPayloadJSON(fractional, on: test.writer)
        }

        // Nothing landed in any failure case.
        #expect(try rowCount(test.writer, table: .gyms) == 0)
    }

    @Test("a newer schema version is rejected with a plain-language message, zero writes (US-16.1)")
    func rejectsNewerVersion() throws {
        let test = try makeTestDatabase()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())
        let before = try test.repos.dump.dumpAll()

        let future = gymsPayloadJSON(schemaVersion: currentSchemaVersion + 1)
        let error = #expect(throws: ImportVersionError.self) {
            try importPayloadJSON(future, on: test.writer)
        }
        #expect(error?.message == """
        This file was created by a newer version of CyberSend (file schema \(currentSchemaVersion + 1), this app runs schema \(currentSchemaVersion)). Update the app first. Nothing was imported.
        """)
        #expect(try test.repos.dump.dumpAll() == before)
    }

    @Test("an older payload migrates forward through the injectable registry (US-16.2)")
    func migratesOlderPayloads() throws {
        let test = try makeTestDatabase()
        let payload = gymsPayloadJSON(schemaVersion: 1)
        let migration = PayloadMigration(from: 1) { parsed in
            var tables = parsed.tables
            var renamed: [ExportRow] = []
            for row in tables[.gyms] ?? [] {
                var copy = row
                copy["name"] = .text("Migrated Gym")
                renamed.append(copy)
            }
            tables[.gyms] = renamed
            return ParsedImportPayload(
                schemaVersion: parsed.schemaVersion,
                exportedAt: parsed.exportedAt,
                legacyShape: parsed.legacyShape,
                tables: tables,
                warnings: parsed.warnings
            )
        }
        let report = try importPayloadJSON(payload, on: test.writer, options: ImportOptions(
            currentVersion: 2,
            payloadMigrations: [migration]
        ))
        #expect(report.schemaVersion == 2)
        #expect(report.migratedFrom == 1)
        #expect(try rowCount(test.writer, table: .gyms) == 1)

        let gym = try test.writer.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM gyms")
        }
        #expect(gym == "Migrated Gym")
    }

    @Test("an older payload without a migration path aborts, zero writes (US-16.2)")
    func rejectsUnmigratablePayload() throws {
        let test = try makeTestDatabase()
        let error = #expect(throws: ImportPayloadError.self) {
            try importPayloadJSON(
                gymsPayloadJSON(schemaVersion: 1),
                on: test.writer,
                options: ImportOptions(currentVersion: 2)
            )
        }
        #expect(error?.message == "This file uses schema version 1, which this app cannot upgrade to version 2. Nothing was imported.")
        #expect(try rowCount(test.writer, table: .gyms) == 0)
    }

    @Test("rows that break foreign key links abort with zero writes (US-16.3)")
    func rejectsForeignKeyViolations() throws {
        let test = try makeTestDatabase()
        let payload = buildExportPayload(
            dump: [
                .sessions: [exportRow(.sessions, [
                    "id": .text("session-1"),
                    "gym_id": .text("missing-gym"),
                    "started_at": .text(fixtureSeedTime),
                    "created_at": .text(fixtureSeedTime),
                    "updated_at": .text(fixtureSeedTime),
                ])],
            ],
            schemaVersion: currentSchemaVersion,
            exportedAt: fixtureExportTime
        )
        let error = #expect(throws: ImportPayloadError.self) {
            try importPayloadJSON(serializeExportPayload(payload), on: test.writer)
        }
        #expect(error?.message == "The file contains rows that break foreign key links. Nothing was imported.")
        #expect(try rowCount(test.writer, table: .sessions) == 0)
    }

    @Test("a database CHECK violation aborts with zero writes (US-16.3)")
    func rejectsCheckViolations() throws {
        let test = try makeTestDatabase()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())
        let badAttempt = exportRow(.attempts, [
            "id": .text("attempt-bad"),
            "session_id": .text("session-1"),
            "climb_id": .text("climb-1"),
            "attempt_no": .integer(2),
            "outcome": .text("bogus"),  // not in the flash/send/project/fail CHECK
            "attempted_at": .text(fixtureSeedTime),
        ])
        let payload = buildExportPayload(
            dump: [.attempts: [badAttempt]],
            schemaVersion: currentSchemaVersion,
            exportedAt: fixtureExportTime
        )
        let error = #expect(throws: ImportPayloadError.self) {
            try importPayloadJSON(serializeExportPayload(payload), on: test.writer)
        }
        #expect(error?.message.contains("Nothing was imported.") == true)
        #expect(try rowCount(test.writer, table: .attempts) == 1, "only the seeded attempt remains")
    }

    @Test("re-import is idempotent by stable id (US-16.4)")
    func reimportIsIdempotent() throws {
        let test = try makeTestDatabase()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())
        let exported = try buildExportJSON(repos: test.repos, now: fixtureExportTime)
        let before = try test.repos.dump.dumpAll()

        let first = try importPayloadJSON(exported, on: test.writer)
        #expect(first.restoredRows == 0)
        #expect(first.updatedRows == before.rows.values.reduce(0) { $0 + $1.count })

        let second = try importPayloadJSON(exported, on: test.writer)
        #expect(second.restoredRows == 0)
        #expect(second.updatedRows == first.updatedRows)
        #expect(try test.repos.dump.dumpAll() == before, "no duplicates and no value drift")
        #expect(try rowCount(test.writer, table: .gyms) == 1)
        #expect(try rowCount(test.writer, table: .attempts) == 1)
    }

    @Test("an existing row is updated in place, never duplicated")
    func updatesExistingRows() throws {
        let test = try makeTestDatabase()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())

        let report = try importPayloadJSON(gymsPayloadJSON(gymID: "gym-1", name: "Renamed"), on: test.writer)
        #expect(report.upserts[.gyms]?.inserted == 0)
        #expect(report.upserts[.gyms]?.updated == 1)
        #expect(try rowCount(test.writer, table: .gyms) == 1)
        let name = try test.writer.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM gyms WHERE id = 'gym-1'")
        }
        #expect(name == "Renamed")
    }

    @Test("migratePayload stamps the target version on the returned payload (TS parity)")
    func migratePayloadStampsTargetVersion() throws {
        let parsed = try parseExportPayload(gymsPayloadJSON(schemaVersion: 1))
        #expect(parsed.schemaVersion == 1)
        let passthrough = PayloadMigration(from: 1) { payload in payload }
        let migrated = try migratePayload(parsed, migrations: [passthrough], targetVersion: 2)
        #expect(migrated.schemaVersion == 2, "the migrated payload carries the target version")
        #expect(migrated.tables == parsed.tables)
        #expect(migrated.exportedAt == parsed.exportedAt)
        #expect(migrated.legacyShape == parsed.legacyShape)
    }

    @Test("a migration that mangled the rows fails revalidation with zero writes (US-16.2)")
    func rejectsMangledMigratedPayload() throws {
        let test = try makeTestDatabase()
        let parsed = try parseExportPayload(gymsPayloadJSON(schemaVersion: 1))

        // Seam: a migration that drops a required column is rejected on the spot,
        // before any database work.
        let dropsColumn = PayloadMigration(from: 1) { payload in
            var tables = payload.tables
            var gyms: [ExportRow] = []
            for row in tables[.gyms] ?? [] {
                var copy = row
                copy.removeValue(forKey: "created_at")
                gyms.append(copy)
            }
            tables[.gyms] = gyms
            return ParsedImportPayload(
                schemaVersion: payload.schemaVersion,
                exportedAt: payload.exportedAt,
                legacyShape: payload.legacyShape,
                tables: tables,
                warnings: payload.warnings
            )
        }
        let seamError = #expect(throws: ImportPayloadError.self) {
            try migratePayload(parsed, migrations: [dropsColumn], targetVersion: 2)
        }
        #expect(seamError?.message == importMigratedInvalidMessage)

        // Full import: a migration that puts the wrong type on a column is rejected
        // with the same invalid-payload semantics as the initial parse, and nothing
        // lands in the database.
        let wrongType = PayloadMigration(from: 1) { payload in
            var tables = payload.tables
            var gyms: [ExportRow] = []
            for row in tables[.gyms] ?? [] {
                var copy = row
                copy["is_archived"] = .text("nope")
                gyms.append(copy)
            }
            tables[.gyms] = gyms
            return ParsedImportPayload(
                schemaVersion: payload.schemaVersion,
                exportedAt: payload.exportedAt,
                legacyShape: payload.legacyShape,
                tables: tables,
                warnings: payload.warnings
            )
        }
        let importError = #expect(throws: ImportPayloadError.self) {
            try importPayloadJSON(
                gymsPayloadJSON(schemaVersion: 1),
                on: test.writer,
                options: ImportOptions(currentVersion: 2, payloadMigrations: [wrongType])
            )
        }
        #expect(importError?.message == "The migrated file is not valid. Nothing was imported.")
        #expect(try rowCount(test.writer, table: .gyms) == 0, "revalidation failed before any write")
    }

    @Test("a native scheme id colliding with a built-in never overwrites the built-in")
    func nativeSchemeIdCollisionKeepsBuiltins() throws {
        let test = try makeTestDatabase()
        // A crafted native file smuggling a fake scheme under the reserved id
        // "v_scale" (is_builtin 0) plus a level and a climb that reference it.
        let payload = buildExportPayload(dump: [
            .gradeSystems: [exportRow(.gradeSystems, [
                "id": .text("v_scale"),
                "name": .text("Fake V Scale"),
                "is_builtin": .integer(0),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ])],
            .gradeLevels: [exportRow(.gradeLevels, [
                "id": .text("v0"),
                "system_id": .text("v_scale"),
                "label": .text("MEGA"),
                "rank_order": .integer(0),
            ])],
            .gyms: [exportRow(.gyms, [
                "id": .text("gym-1"),
                "name": .text("Boulder Garden"),
                "is_archived": .integer(0),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ])],
            .climbs: [exportRow(.climbs, [
                "id": .text("climb-1"),
                "gym_id": .text("gym-1"),
                "name": .text("Fake V scale project"),
                "grade_system_id": .text("v_scale"),
                "grade_level_id": .text("v0"),
                "is_active": .integer(1),
                "is_archived": .integer(0),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ])],
        ], schemaVersion: currentSchemaVersion, exportedAt: fixtureExportTime)

        let report = try importPayloadJSON(serializeExportPayload(payload), on: test.writer)
        #expect(report.restoredRows > 0, "the import still succeeds")
        #expect(report.warnings.contains {
            $0.contains("v_scale") && $0.contains("v_scale_imported") && $0.contains("built-in")
        })
        #expect(report.warnings.contains {
            $0.contains("v0") && $0.contains("v0_imported") && $0.contains("built-in")
        })

        let dump = try test.repos.dump.dumpAll()
        let systems = dump[.gradeSystems] ?? []
        let vScale = systems.first { $0["id"] == .text("v_scale") }
        #expect(vScale?["is_builtin"] == .integer(1), "no is_builtin flip on the built-in")
        #expect(vScale?["name"] == .text("V Scale"), "the built-in name stays")
        #expect(systems.count == 3, "two built-ins plus the renamed import")
        let renamed = systems.first { $0["id"] == .text("v_scale_imported") }
        #expect(renamed?["is_builtin"] == .integer(0))
        #expect(renamed?["name"] == .text("Fake V Scale"))

        // The built-in levels are untouched; the colliding import level lands renamed.
        let levels = dump[.gradeLevels] ?? []
        #expect(levels.count == builtinGradeLevelIDs.count + 1, "44 built-ins plus the renamed import level")
        let v0 = levels.first { $0["id"] == .text("v0") }
        #expect(v0?["label"] == .text("V0"), "the built-in V0 label stays")
        #expect(v0?["system_id"] == .text("v_scale"))
        let renamedLevel = levels.first { $0["id"] == .text("v0_imported") }
        #expect(renamedLevel?["label"] == .text("MEGA"))
        #expect(renamedLevel?["system_id"] == .text("v_scale_imported"))

        // The climb follows the renamed rows, so its foreign keys stay valid.
        let climbs = dump[.climbs] ?? []
        #expect(climbs.count == 1)
        #expect(climbs[0]["grade_system_id"] == .text("v_scale_imported"))
        #expect(climbs[0]["grade_level_id"] == .text("v0_imported"))
    }

    @Test("a native level id colliding with a built-in never overwrites the built-in level")
    func nativeLevelIdCollisionKeepsBuiltins() throws {
        let test = try makeTestDatabase()
        // A crafted native file smuggling a level under the reserved id "v4" inside an
        // otherwise ordinary custom scheme, plus a climb that references it.
        let payload = buildExportPayload(dump: [
            .gradeSystems: [exportRow(.gradeSystems, [
                "id": .text("kilter_soft"),
                "name": .text("Kilter Soft"),
                "is_builtin": .integer(0),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ])],
            .gradeLevels: [exportRow(.gradeLevels, [
                "id": .text("v4"),
                "system_id": .text("kilter_soft"),
                "label": .text("Hacked"),
                "rank_order": .integer(4),
            ])],
            .gyms: [exportRow(.gyms, [
                "id": .text("gym-1"),
                "name": .text("Boulder Garden"),
                "is_archived": .integer(0),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ])],
            .climbs: [exportRow(.climbs, [
                "id": .text("climb-1"),
                "gym_id": .text("gym-1"),
                "name": .text("Kilter slab"),
                "grade_system_id": .text("kilter_soft"),
                "grade_level_id": .text("v4"),
                "is_active": .integer(1),
                "is_archived": .integer(0),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ])],
        ], schemaVersion: currentSchemaVersion, exportedAt: fixtureExportTime)

        let report = try importPayloadJSON(serializeExportPayload(payload), on: test.writer)
        #expect(report.restoredRows > 0, "the import still succeeds")
        #expect(report.warnings.contains {
            $0.contains("v4") && $0.contains("v4_imported") && $0.contains("built-in")
        })

        let dump = try test.repos.dump.dumpAll()
        let vScale = (dump[.gradeSystems] ?? []).first { $0["id"] == .text("v_scale") }
        #expect(vScale?["is_builtin"] == .integer(1), "no is_builtin flip on the built-in")
        let kilter = (dump[.gradeSystems] ?? []).first { $0["id"] == .text("kilter_soft") }
        #expect(kilter?["is_builtin"] == .integer(0))
        #expect(kilter?["name"] == .text("Kilter Soft"))

        let levels = dump[.gradeLevels] ?? []
        #expect(levels.count == builtinGradeLevelIDs.count + 1, "44 built-ins plus the renamed level")
        let v4 = levels.first { $0["id"] == .text("v4") }
        #expect(v4?["label"] == .text("V4"), "the built-in V4 label stays")
        #expect(v4?["system_id"] == .text("v_scale"))
        let renamed = levels.first { $0["id"] == .text("v4_imported") }
        #expect(renamed?["label"] == .text("Hacked"))
        #expect(renamed?["system_id"] == .text("kilter_soft"))

        // The climb keeps its scheme and follows the renamed level.
        let climbs = dump[.climbs] ?? []
        #expect(climbs.count == 1)
        #expect(climbs[0]["grade_system_id"] == .text("kilter_soft"))
        #expect(climbs[0]["grade_level_id"] == .text("v4_imported"))
    }
}
