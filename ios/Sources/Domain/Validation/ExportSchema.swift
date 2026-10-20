import Foundation

// Export payload table metadata (port of src/domain/validation/tables.ts, reconciled with
// docs/schema.sql per the schema reconciliation record in docs/decisions.md). Two payload
// shapes exist:
//
//  * native: the reconciled Swift schema (15 tables, normalized grade_systems and
//    grade_levels, holds.role, attempts.fall_on_hold_id and attempts.attempted_at,
//    gyms.is_archived).
//  * legacy: the frozen TypeScript spec shape (13 tables, climbs.grade_system and
//    climbs.grade_raw text, holds.label and holds.color, attempts.fell_on_hold_id and
//    attempts.created_at, gyms.is_active).
//
// Export always writes native. Import accepts both: old exports must always import
// (US-16), so the parser validates either shape strictly (no unknown columns, exact
// types) and translates legacy rows to native columns.

public enum ExportColumnType: String, Equatable, Sendable {
    case text
    case integer
    case real
}

public struct ExportColumn: Equatable, Sendable {
    public let name: String
    public let type: ExportColumnType
    public let nullable: Bool

    public init(name: String, type: ExportColumnType, nullable: Bool) {
        self.name = name
        self.type = type
        self.nullable = nullable
    }
}

/// An ordered column whitelist for one table. Column names come from this list only,
/// never from imported data, so every SQL statement built from it is injection safe.
public struct ExportTableSpec: Equatable, Sendable {
    public let columns: [ExportColumn]
    /// The upsert conflict target: "key" for settings, "id" everywhere else.
    public let conflictTarget: String

    public init(columns: [ExportColumn], conflictTarget: String = "id") {
        self.columns = columns
        self.conflictTarget = conflictTarget
    }

    public var columnNames: [String] {
        columns.map(\.name)
    }

    public func column(named name: String) -> ExportColumn? {
        columns.first { $0.name == name }
    }
}

/// Convenience constructor for an export column.
private func column(_ name: String, _ type: ExportColumnType, nullable: Bool = false) -> ExportColumn {
    ExportColumn(name: name, type: type, nullable: nullable)
}

/// Every entity table in the database, in FK safe insert order (parents before children
/// so foreign key checks pass during import). schema_migrations and GRDB's bookkeeping
/// tables are excluded, exactly like the TypeScript TABLES_IN_INSERT_ORDER.
public enum ExportTable: String, CaseIterable, Sendable {
    case gradeSystems = "grade_systems"
    case gradeLevels = "grade_levels"
    case gyms = "gyms"
    case walls = "walls"
    case boards = "boards"
    case boardProblems = "board_problems"
    case climbs = "climbs"
    case holds = "holds"
    case sessions = "sessions"
    case photos = "photos"
    case videos = "videos"
    case poseKeypoints = "pose_keypoints"
    case attempts = "attempts"
    case gradeNormParams = "grade_norm_params"
    case settings = "settings"

    /// Declaration order is the insert order (grade tables first because climbs reference
    /// them, everything else mirrors the TypeScript order).
    public var spec: ExportTableSpec {
        switch self {
        case .gradeSystems:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("name", .text),
                column("is_builtin", .integer),
                column("created_at", .text),
                column("updated_at", .text),
            ])
        case .gradeLevels:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("system_id", .text),
                column("label", .text),
                column("rank_order", .integer),
                column("color_hex", .text, nullable: true),
            ])
        case .gyms:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("name", .text),
                column("timezone", .text, nullable: true),
                column("is_archived", .integer),
                column("created_at", .text),
                column("updated_at", .text),
            ])
        case .walls:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("gym_id", .text),
                column("name", .text, nullable: true),
                column("angle_deg", .real, nullable: true),
                column("angle_label", .text, nullable: true),
                column("is_active", .integer),
                column("created_at", .text),
                column("updated_at", .text),
            ])
        case .boards:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("provider", .text),
                column("name", .text),
                column("angle_deg", .real, nullable: true),
                column("created_at", .text),
                column("updated_at", .text),
            ])
        case .boardProblems:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("board_id", .text),
                column("provider", .text),
                column("external_id", .text, nullable: true),
                column("name", .text, nullable: true),
                column("grade_raw", .text, nullable: true),
                column("angle_deg", .real, nullable: true),
                column("holds_json", .text),
                column("is_active", .integer),
                column("imported_at", .text),
            ])
        case .climbs:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("gym_id", .text),
                column("wall_id", .text, nullable: true),
                column("board_id", .text, nullable: true),
                column("board_problem_id", .text, nullable: true),
                column("name", .text, nullable: true),
                column("grade_system_id", .text),
                column("grade_level_id", .text, nullable: true),
                column("grade_norm", .real, nullable: true),
                column("color_circuit", .text, nullable: true),
                column("angle_deg", .real, nullable: true),
                column("is_active", .integer),
                column("is_archived", .integer),
                column("created_at", .text),
                column("updated_at", .text),
            ])
        case .holds:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("climb_id", .text),
                column("x_norm", .real),
                column("y_norm", .real),
                column("radius_norm", .real),
                column("role", .text, nullable: true),
                column("color_family", .text, nullable: true),
                column("source", .text),
                column("ordinal", .integer, nullable: true),
                column("created_at", .text),
                column("updated_at", .text),
            ])
        case .sessions:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("gym_id", .text),
                column("started_at", .text),
                column("ended_at", .text, nullable: true),
                column("rpe", .integer, nullable: true),
                column("notes", .text, nullable: true),
                column("created_at", .text),
                column("updated_at", .text),
            ])
        case .photos:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("climb_id", .text, nullable: true),
                column("session_id", .text, nullable: true),
                column("uri", .text),
                column("thumb_uri", .text, nullable: true),
                column("width", .integer),
                column("height", .integer),
                column("source", .text),
                column("captured_at", .text),
                column("created_at", .text),
            ])
        case .videos:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("session_id", .text, nullable: true),
                column("climb_id", .text, nullable: true),
                column("uri", .text),
                column("width", .integer, nullable: true),
                column("height", .integer, nullable: true),
                column("duration_ms", .integer, nullable: true),
                column("fps", .real, nullable: true),
                column("pose_status", .text),
                column("retention_class", .text),
                column("created_at", .text),
            ])
        case .poseKeypoints:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("video_id", .text),
                column("t_ms", .integer),
                column("score", .real, nullable: true),
                column("keypoints_json", .text),
            ])
        case .attempts:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("session_id", .text),
                column("climb_id", .text),
                column("attempt_no", .integer),
                column("outcome", .text),
                column("fall_on_hold_id", .text, nullable: true),
                column("video_id", .text, nullable: true),
                column("notes", .text, nullable: true),
                column("attempted_at", .text),
            ])
        case .gradeNormParams:
            return ExportTableSpec(columns: [
                column("id", .text),
                column("scope", .text),
                column("gym_id", .text, nullable: true),
                column("algo_version", .text),
                column("sample_count", .integer),
                column("params_json", .text),
                column("computed_at", .text),
            ])
        case .settings:
            return ExportTableSpec(columns: [
                column("key", .text),
                column("value_json", .text),
                column("updated_at", .text),
            ], conflictTarget: "key")
        }
    }
}

/// The legacy TypeScript spec shape (src/domain/validation/tables.ts) keyed by table
/// name. Only the four reconciled tables differ from the native spec; the rest are
/// byte identical.
public let legacyExportTableSpecs: [String: ExportTableSpec] = [
    "gyms": ExportTableSpec(columns: [
        column("id", .text),
        column("name", .text),
        column("timezone", .text, nullable: true),
        column("is_active", .integer),
        column("created_at", .text),
        column("updated_at", .text),
    ]),
    "walls": ExportTableSpec(columns: [
        column("id", .text),
        column("gym_id", .text),
        column("name", .text, nullable: true),
        column("angle_deg", .real, nullable: true),
        column("angle_label", .text, nullable: true),
        column("is_active", .integer),
        column("created_at", .text),
        column("updated_at", .text),
    ]),
    "boards": ExportTableSpec(columns: [
        column("id", .text),
        column("provider", .text),
        column("name", .text),
        column("angle_deg", .real, nullable: true),
        column("created_at", .text),
        column("updated_at", .text),
    ]),
    "board_problems": ExportTableSpec(columns: [
        column("id", .text),
        column("board_id", .text),
        column("provider", .text),
        column("external_id", .text, nullable: true),
        column("name", .text, nullable: true),
        column("grade_raw", .text, nullable: true),
        column("angle_deg", .real, nullable: true),
        column("holds_json", .text),
        column("is_active", .integer),
        column("imported_at", .text),
    ]),
    "climbs": ExportTableSpec(columns: [
        column("id", .text),
        column("gym_id", .text),
        column("wall_id", .text, nullable: true),
        column("board_id", .text, nullable: true),
        column("board_problem_id", .text, nullable: true),
        column("name", .text, nullable: true),
        column("grade_system", .text),
        column("grade_raw", .text, nullable: true),
        column("grade_norm", .real, nullable: true),
        column("color_circuit", .text, nullable: true),
        column("angle_deg", .real, nullable: true),
        column("is_active", .integer),
        column("is_archived", .integer),
        column("created_at", .text),
        column("updated_at", .text),
    ]),
    "holds": ExportTableSpec(columns: [
        column("id", .text),
        column("climb_id", .text),
        column("x_norm", .real),
        column("y_norm", .real),
        column("radius_norm", .real),
        column("label", .text, nullable: true),
        column("color", .text, nullable: true),
        column("source", .text),
        column("ordinal", .integer, nullable: true),
        column("created_at", .text),
        column("updated_at", .text),
    ]),
    "sessions": ExportTableSpec(columns: [
        column("id", .text),
        column("gym_id", .text),
        column("started_at", .text),
        column("ended_at", .text, nullable: true),
        column("rpe", .integer, nullable: true),
        column("notes", .text, nullable: true),
        column("created_at", .text),
        column("updated_at", .text),
    ]),
    "photos": ExportTableSpec(columns: [
        column("id", .text),
        column("climb_id", .text, nullable: true),
        column("session_id", .text, nullable: true),
        column("uri", .text),
        column("thumb_uri", .text, nullable: true),
        column("width", .integer),
        column("height", .integer),
        column("source", .text),
        column("captured_at", .text),
        column("created_at", .text),
    ]),
    "videos": ExportTableSpec(columns: [
        column("id", .text),
        column("session_id", .text, nullable: true),
        column("climb_id", .text, nullable: true),
        column("uri", .text),
        column("width", .integer, nullable: true),
        column("height", .integer, nullable: true),
        column("duration_ms", .integer, nullable: true),
        column("fps", .real, nullable: true),
        column("pose_status", .text),
        column("retention_class", .text),
        column("created_at", .text),
    ]),
    "pose_keypoints": ExportTableSpec(columns: [
        column("id", .text),
        column("video_id", .text),
        column("t_ms", .integer),
        column("score", .real, nullable: true),
        column("keypoints_json", .text),
    ]),
    "attempts": ExportTableSpec(columns: [
        column("id", .text),
        column("session_id", .text),
        column("climb_id", .text),
        column("attempt_no", .integer),
        column("outcome", .text),
        column("fell_on_hold_id", .text, nullable: true),
        column("video_id", .text, nullable: true),
        column("notes", .text, nullable: true),
        column("created_at", .text),
    ]),
    "grade_norm_params": ExportTableSpec(columns: [
        column("id", .text),
        column("scope", .text),
        column("gym_id", .text, nullable: true),
        column("algo_version", .text),
        column("sample_count", .integer),
        column("params_json", .text),
        column("computed_at", .text),
    ]),
    "settings": ExportTableSpec(columns: [
        column("key", .text),
        column("value_json", .text),
        column("updated_at", .text),
    ], conflictTarget: "key"),
]

/// The legacy table names in FK safe insert order.
public let legacyTableNamesInInsertOrder: [String] = [
    "gyms",
    "walls",
    "boards",
    "board_problems",
    "climbs",
    "holds",
    "sessions",
    "photos",
    "videos",
    "pose_keypoints",
    "attempts",
    "grade_norm_params",
    "settings",
]

/// One JSON safe cell value. docs/schema.sql has no BLOB columns, so text, integer,
/// real, and null cover every stored value (the TypeScript ExportRow equivalent).
public enum ExportValue: Equatable, Sendable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null

    public var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var integerValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var realValue: Double? {
        switch self {
        case .real(let value):
            return value
        case .integer(let value):
            return Double(value)
        default:
            return nil
        }
    }
}

/// One exported row: column name to value, validated against the table spec.
public typealias ExportRow = [String: ExportValue]
