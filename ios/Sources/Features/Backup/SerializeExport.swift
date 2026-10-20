import CyberSendDomain
import Foundation

// Pure export payload construction and JSON serialization (port of
// src/features/backup/serialize.ts). US-14.1: JSON contains every entity plus
// schema_version and round-trips losslessly.

/// The export payload built from a table dump.
public struct ExportPayload: Equatable, Sendable {
    public let app: String
    public let schemaVersion: Int
    public let exportedAt: String
    public let tables: [ExportTable: [ExportRow]]

    public init(app: String, schemaVersion: Int, exportedAt: String, tables: [ExportTable: [ExportRow]]) {
        self.app = app
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.tables = tables
    }
}

/// Every table is present in the payload, even when empty, so import validation is
/// uniform (port of build_export_payload).
public func buildExportPayload(
    dump: [ExportTable: [ExportRow]],
    schemaVersion: Int,
    exportedAt: String
) -> ExportPayload {
    var tables: [ExportTable: [ExportRow]] = [:]
    for table in ExportTable.allCases {
        tables[table] = dump[table] ?? []
    }
    return ExportPayload(
        app: exportAppID,
        schemaVersion: schemaVersion,
        exportedAt: exportedAt,
        tables: tables
    )
}

/// Deterministic JSON text, byte compatible with the TypeScript JSON.stringify(payload,
/// null, 2) output for the same data (port of serialize_export_payload).
public func serializeExportPayload(_ payload: ExportPayload) -> String {
    let tableEntries: [(String, JSONNode)] = ExportTable.allCases.map { table in
        let rows = (payload.tables[table] ?? []).map { row in
            JSONNode.object(table.spec.columns.map { column in
                (column.name, jsonNode(for: row[column.name] ?? .null, type: column.type))
            })
        }
        return (table.rawValue, JSONNode.array(rows))
    }
    let root = JSONNode.object([
        ("app", .string(payload.app)),
        ("schema_version", .number(String(payload.schemaVersion))),
        ("exported_at", .string(payload.exportedAt)),
        ("tables", .object(tableEntries)),
    ])
    return JSONRenderer.render(root)
}
