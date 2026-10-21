import Foundation
import GRDB
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Shared support for the backup, import, CSV, and flags suites (M1). The seed fixture
// uses fixed ids and timestamps so the golden data.json bytes are reproducible.

let fixtureSeedTime = "2026-10-01T00:00:00.000Z"
let fixtureExportTime = "2026-10-19T12:00:00.000Z"

/// Builds one row for a table from the spec columns; unlisted columns bind as null.
func exportRow(_ table: ExportTable, _ values: [String: ExportValue]) -> ExportRow {
    var row: ExportRow = [:]
    for column in table.spec.columns {
        row[column.name] = values[column.name] ?? .null
    }
    return row
}

/// The deterministic seed used by the golden fixture and the round trip tests: one of
/// most things plus one custom grade scheme, exercising nulls, integers, reals, and
/// JSON escaping in the session notes and climb name.
func goldenSeedRows() -> [ExportTable: [ExportRow]] {
    [
        .gradeSystems: [
            exportRow(.gradeSystems, [
                "id": .text("kilter_soft"),
                "name": .text("Kilter Soft"),
                "is_builtin": .integer(0),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ]),
        ],
        .gradeLevels: [
            exportRow(.gradeLevels, [
                "id": .text("kilter_soft_l0"),
                "system_id": .text("kilter_soft"),
                "label": .text("KB1"),
                "rank_order": .integer(0),
                "color_hex": .null,
            ]),
        ],
        .gyms: [
            exportRow(.gyms, [
                "id": .text("gym-1"),
                "name": .text("Boulder Garden"),
                "timezone": .text("America/Denver"),
                "is_archived": .integer(0),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ]),
        ],
        .climbs: [
            exportRow(.climbs, [
                "id": .text("climb-1"),
                "gym_id": .text("gym-1"),
                "name": .text("Blue \"V4\" slab"),
                "grade_system_id": .text("v_scale"),
                "grade_level_id": .text("v4"),
                "color_circuit": .text("blue"),
                "angle_deg": .real(30),
                "is_active": .integer(1),
                "is_archived": .integer(0),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ]),
        ],
        .holds: [
            exportRow(.holds, [
                "id": .text("hold-1"),
                "climb_id": .text("climb-1"),
                "x_norm": .real(0.5),
                "y_norm": .real(0.55),
                "radius_norm": .real(0.02),
                "role": .text("start"),
                "color_family": .text("blue"),
                "source": .text("manual"),
                "ordinal": .integer(1),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ]),
        ],
        .climbHolds: [
            exportRow(.climbHolds, [
                "climb_id": .text("climb-1"),
                "hold_id": .text("hold-1"),
                "sequence": .integer(1),
                "created_at": .text(fixtureSeedTime),
            ]),
        ],
        .sessions: [
            exportRow(.sessions, [
                "id": .text("session-1"),
                "gym_id": .text("gym-1"),
                "started_at": .text(fixtureSeedTime),
                "ended_at": .text(fixtureSeedTime),
                "rpe": .integer(7),
                "notes": .text("Crims, \"pinches\"\nand slopers"),
                "created_at": .text(fixtureSeedTime),
                "updated_at": .text(fixtureSeedTime),
            ]),
        ],
        .photos: [
            exportRow(.photos, [
                "id": .text("photo-1"),
                "climb_id": .text("climb-1"),
                "uri": .text("photos/photo-1.jpg"),
                "thumb_uri": .text("thumbs/photo-1.jpg"),
                "original_uri": .text("originals/photo-1.jpg"),
                "width": .integer(4032),
                "height": .integer(3024),
                "source": .text("camera"),
                "captured_at": .text(fixtureSeedTime),
                "created_at": .text(fixtureSeedTime),
            ]),
        ],
        .attempts: [
            exportRow(.attempts, [
                "id": .text("attempt-1"),
                "session_id": .text("session-1"),
                "climb_id": .text("climb-1"),
                "attempt_no": .integer(1),
                "outcome": .text("send"),
                "fall_on_hold_id": .text("hold-1"),
                "attempted_at": .text(fixtureSeedTime),
            ]),
        ],
        .settings: [
            exportRow(.settings, [
                "key": .text("gym.default_id"),
                "value_json": .text("\"gym-1\""),
                "updated_at": .text(fixtureSeedTime),
            ]),
        ],
    ]
}

/// Upserts rows through the dump repository, exactly like an import would.
func seedDatabase(_ writer: any DatabaseWriter, repos: Repositories, rows: [ExportTable: [ExportRow]]) throws {
    try withTransaction(on: writer) { db in
        _ = try repos.dump.upsertAll(rows, on: db)
    }
}

/// Loads a golden fixture file from Tests/Fixtures (bundled as a test resource).
func fixtureString(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
          let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)
    else {
        struct MissingFixture: Error {}
        throw MissingFixture()
    }
    return text
}

/// Row count helper for zero-write assertions.
func rowCount(_ writer: any DatabaseWriter, table: ExportTable) throws -> Int {
    try writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.rawValue)") ?? 0
    }
}

/// A minimal valid native payload JSON for one gyms row.
func gymsPayloadJSON(gymID: String = "gym-import", name: String = "Import Gym", schemaVersion: Int = 1) -> String {
    serializeExportPayload(buildExportPayload(
        dump: [.gyms: [exportRow(.gyms, [
            "id": .text(gymID),
            "name": .text(name),
            "timezone": .null,
            "is_archived": .integer(0),
            "created_at": .text(fixtureSeedTime),
            "updated_at": .text(fixtureSeedTime),
        ])]],
        schemaVersion: schemaVersion,
        exportedAt: fixtureExportTime
    ))
}
