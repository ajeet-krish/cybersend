import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Export payload serialization (US-14.1): every entity plus schema_version, lossless
// round trip, and byte identical output against the golden fixture.

@Suite("Export serialization")
struct ExportSerializeTests {
    @Test("payload contains every table in insert order, even when empty")
    func payloadContainsEveryTable() throws {
        let test = try makeTestDatabase()
        let json = try buildExportJSON(repos: test.repos, now: fixtureExportTime)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["app"] as? String == "cybersend")
        #expect(object["schema_version"] as? Int == currentSchemaVersion)
        let tables = try #require(object["tables"] as? [String: Any])
        #expect(Set(tables.keys) == Set(ExportTable.allCases.map(\.rawValue)))
        for (name, value) in tables {
            #expect(value is [Any], "\(name) should be an array")
        }
    }

    @Test("golden v5 export matches the fixture byte for byte")
    func goldenBytesMatch() throws {
        // Serialization only, no database: the fixture pins the exact bytes the exporter
        // produces for the seed dump at schema version 5, so any drift in table order,
        // column order, key order, number formatting, or escaping fails here. The
        // formatting is cross-checked against Node JSON.stringify(payload, null, 2). The
        // v2, v3, and v4 fixtures stay in the tree as import compatibility inputs: they are
        // the shapes earlier builds actually wrote, and each differs from this one only by
        // schema_version plus the columns added since (attempts.rpe, climbs.notes,
        // climbs.categories).
        let json = serializeExportPayload(buildExportPayload(
            dump: goldenSeedRows(),
            schemaVersion: 5,
            exportedAt: fixtureExportTime
        ))
        let golden = try fixtureString("data_native_golden_v5")
        #expect(json == golden)
        #expect(Data(json.utf8) == Data(golden.utf8))
    }

    @Test("the pinned v1 fixture still parses as a native version 1 payload")
    func pinnedV1FixtureParsesAsV1() throws {
        let parsed = try parseExportPayload(try fixtureString("data_native_v1"))
        #expect(parsed.schemaVersion == 1)
        #expect(parsed.legacyShape == false)
        #expect(parsed.tables[.climbHolds] == nil, "the v1 shape has no climb_holds table")
        #expect(parsed.tables[.photos]?[0]["original_uri"] == nil, "the v1 photos rows predate original_uri")
    }

    @Test("serialization is deterministic for the same seed")
    func serializationIsDeterministic() throws {
        let test = try makeTestDatabase()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())
        let first = try buildExportJSON(repos: test.repos, now: fixtureExportTime)
        let second = try buildExportJSON(repos: test.repos, now: fixtureExportTime)
        #expect(first == second)
    }

    @Test("export then wipe then import is lossless (US-14.1 round trip)")
    func roundTripIsLossless() throws {
        let source = try makeTestDatabase()
        try seedDatabase(source.writer, repos: source.repos, rows: goldenSeedRows())
        let exported = try buildExportJSON(repos: source.repos, now: fixtureExportTime)
        let before = try source.repos.dump.dumpAll()

        let target = try makeTestDatabase()
        let report = try importPayloadJSON(exported, on: target.writer)
        #expect(report.schemaVersion == currentSchemaVersion)
        #expect(report.migratedFrom == nil)
        #expect(report.warnings.isEmpty)

        let after = try target.repos.dump.dumpAll()
        #expect(before.rows.count == after.rows.count)
        for table in ExportTable.allCases {
            #expect(before[table] == after[table], "table \(table.rawValue) must round trip losslessly")
        }
    }

    @Test("JSON string escaping matches JSON.stringify rules")
    func escapingMatchesJSONStringify() {
        #expect(JSONRenderer.escape("plain") == "\"plain\"")
        #expect(JSONRenderer.escape("has \"quotes\"") == "\"has \\\"quotes\\\"\"")
        #expect(JSONRenderer.escape("back\\slash") == "\"back\\\\slash\"")
        #expect(JSONRenderer.escape("line\nbreak") == "\"line\\nbreak\"")
        #expect(JSONRenderer.escape("carriage\rreturn") == "\"carriage\\rreturn\"")
        #expect(JSONRenderer.escape("tab\there") == "\"tab\\there\"")
        #expect(JSONRenderer.escape("\u{07}bell") == "\"\\u0007bell\"")
        #expect(JSONRenderer.escape("héllo") == "\"héllo\"")
    }

    @Test("real columns render integral values without a decimal point, like JS")
    func numberFormattingMatchesJS() {
        #expect(jsNumberString(30) == "30")
        #expect(jsNumberString(0.5) == "0.5")
        #expect(jsNumberString(0.02) == "0.02")
        #expect(jsNumberString(-1.25) == "-1.25")
        #expect(jsNumberString(.infinity) == "null")
    }

    @Test("dump repository reads schema version and every table")
    func dumpRepositoryCoversEveryTable() throws {
        let test = try makeTestDatabase()
        let dump = try test.repos.dump.dumpAll()
        #expect(Set(dump.rows.keys) == Set(ExportTable.allCases))
        #expect(try test.repos.dump.schemaVersion() == currentSchemaVersion)
        // The migration seeded built-in grade schemes into the dump.
        #expect(dump[.gradeSystems].count == 2)
        #expect(dump[.gradeLevels].count == 44)
        #expect(dump[.gyms].isEmpty)
    }
}
