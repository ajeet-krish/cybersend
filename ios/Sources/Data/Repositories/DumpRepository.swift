import CyberSendDomain
import Foundation
import GRDB

// Dump repository (port of src/data/repositories/dump_repository.ts): raw table dumps for
// backup export and validated upserts for import. Still a repository, so the SQL stays in
// Sources/Data (US-13). Rows are JSON safe plain records (TEXT, INTEGER, REAL only;
// docs/schema.sql has no BLOB columns).

/// All entity tables dumped from one database.
public struct TableDump: Equatable, Sendable {
    public let rows: [ExportTable: [ExportRow]]

    public init(rows: [ExportTable: [ExportRow]]) {
        self.rows = rows
    }

    public subscript(_ table: ExportTable) -> [ExportRow] {
        rows[table] ?? []
    }
}

public struct UpsertCounts: Equatable, Sendable {
    public let inserted: Int
    public let updated: Int

    public init(inserted: Int, updated: Int) {
        self.inserted = inserted
        self.updated = updated
    }
}

/// Per table inserted and updated counts for one import.
public typealias UpsertReport = [ExportTable: UpsertCounts]

/// One row of PRAGMA foreign_key_check: the row at `rowid` in `table` has a foreign key
/// (number `foreignKeyIndex`) pointing at a missing parent row in `parentTable`. An
/// empty result means every foreign key link is intact.
public struct ForeignKeyViolation: Equatable, Sendable {
    public let table: String
    public let rowid: Int64?
    public let parentTable: String
    public let foreignKeyIndex: Int

    public init(table: String, rowid: Int64?, parentTable: String, foreignKeyIndex: Int) {
        self.table = table
        self.rowid = rowid
        self.parentTable = parentTable
        self.foreignKeyIndex = foreignKeyIndex
    }
}

public enum DumpError: Error, Equatable, CustomStringConvertible, Sendable {
    case unsupportedColumnType

    public var description: String {
        "Dump failed: unsupported column value type in the database."
    }
}

public protocol DumpRepository: Sendable {
    /// PRAGMA user_version, the schema version of the database.
    func schemaVersion() throws -> Int
    /// Every entity table, in FK safe insert order.
    func dumpAll() throws -> TableDump
    /// Upserts rows in FK safe order. The caller wraps this in a transaction so a
    /// failure anywhere rolls back every table (zero partial writes).
    func upsertAll(_ tables: [ExportTable: [ExportRow]], on db: Database) throws -> UpsertReport
    /// PRAGMA foreign_key_check: every foreign key link that points at a missing parent
    /// row, empty when the data is intact. The import service runs this inside its
    /// transaction before commit (US-16.3); the SQL stays in Sources/Data.
    func foreignKeyCheck(on db: Database) throws -> [ForeignKeyViolation]
}

public struct GRDBDumpRepository: DumpRepository {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func schemaVersion() throws -> Int {
        try writer.read { db in
            try readSchemaVersion(on: db)
        }
    }

    public func dumpAll() throws -> TableDump {
        try writer.read { db in
            var dump: [ExportTable: [ExportRow]] = [:]
            for table in ExportTable.allCases {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table.rawValue)")
                dump[table] = try rows.map { try exportRow(from: $0) }
            }
            return TableDump(rows: dump)
        }
    }

    public func upsertAll(_ tables: [ExportTable: [ExportRow]], on db: Database) throws -> UpsertReport {
        var report: UpsertReport = [:]
        for table in ExportTable.allCases {
            let spec = table.spec
            let insertSQL = upsertSQL(table: table, spec: spec)
            let existsSQL = selectConflictSQL(table: table, spec: spec)
            var counts = UpsertCounts(inserted: 0, updated: 0)
            for row in tables[table] ?? [] {
                let target = row[spec.conflictTarget] ?? .null
                let present = try Row.fetchOne(
                    db,
                    sql: existsSQL,
                    arguments: StatementArguments([bindableValue(of: target)])
                ) != nil
                let arguments = StatementArguments(spec.columnNames.map { bindableValue(of: row[$0] ?? .null) })
                do {
                    try db.execute(sql: insertSQL, arguments: arguments)
                } catch {
                    throw mappedImportConstraintError(error)
                }
                if present {
                    counts = UpsertCounts(inserted: counts.inserted, updated: counts.updated + 1)
                } else {
                    counts = UpsertCounts(inserted: counts.inserted + 1, updated: counts.updated)
                }
            }
            report[table] = counts
        }
        return report
    }

    public func foreignKeyCheck(on db: Database) throws -> [ForeignKeyViolation] {
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").map { row in
            let table: String = row["table"] ?? ""
            let rowid: Int64? = row["rowid"]
            let parent: String = row["parent"] ?? ""
            let foreignKeyIndex: Int = row["fkid"] ?? 0
            return ForeignKeyViolation(
                table: table,
                rowid: rowid,
                parentTable: parent,
                foreignKeyIndex: foreignKeyIndex
            )
        }
    }
}

private func exportRow(from row: Row) throws -> ExportRow {
    var result: ExportRow = [:]
    for (index, name) in row.columnNames.enumerated() {
        let value = row[index]?.databaseValue ?? .null
        switch value.storage {
        case .null:
            result[name] = .null
        case .int64(let integer):
            result[name] = .integer(integer)
        case .double(let double):
            result[name] = .real(double)
        case .string(let text):
            result[name] = .text(text)
        case .blob:
            throw DumpError.unsupportedColumnType
        }
    }
    return result
}

/// ExportValue as a bindable GRDB value; null binds as SQL NULL.
private func bindableValue(of value: ExportValue) -> (any DatabaseValueConvertible)? {
    switch value {
    case .text(let text):
        return text
    case .integer(let integer):
        return integer
    case .real(let double):
        return double
    case .null:
        return nil
    }
}

/// Builds an upsert statement from the fixed column whitelist. Column names never come
/// from imported data, only from ExportTable.spec, so this is injection safe.
private func upsertSQL(table: ExportTable, spec: ExportTableSpec) -> String {
    let columns = spec.columnNames
    let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
    let updates = columns
        .filter { $0 != spec.conflictTarget }
        .map { "\($0) = excluded.\($0)" }
        .joined(separator: ", ")
    return """
    INSERT INTO \(table.rawValue) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))
    ON CONFLICT(\(spec.conflictTarget)) DO UPDATE SET \(updates)
    """
}

private func selectConflictSQL(table: ExportTable, spec: ExportTableSpec) -> String {
    "SELECT 1 AS present FROM \(table.rawValue) WHERE \(spec.conflictTarget) = ?"
}

/// Maps GRDB constraint failures to the plain-language import errors of the TypeScript
/// service. The staging load and the transaction both run validated payloads, so a
/// constraint failure means the file breaks database rules (foreign keys, CHECKs,
/// uniqueness) even though its columns and types are well formed. Used by the import
/// service in Features as well as by upsertAll.
public func mappedImportConstraintError(_ error: Error) -> Error {
    guard let databaseError = error as? DatabaseError else {
        return error
    }
    if databaseError.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
        return ImportPayloadError(importForeignKeyMessage)
    }
    if databaseError.resultCode == .SQLITE_CONSTRAINT {
        return ImportPayloadError(importInvalidPayloadMessage)
    }
    return error
}
