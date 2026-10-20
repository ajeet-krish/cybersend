import Foundation

// Export payload parsing and validation (port of the zod schemas in
// src/domain/validation/tables.ts plus the validation half of
// src/features/backup/import_service.ts). Order of operations guarantees zero writes on
// any failure: parse JSON, validate every row strictly (exact columns, exact types),
// reject newer schema versions, migrate older payloads forward. The parser also accepts
// the legacy TypeScript shape and translates old column names to the reconciled schema
// (docs/decisions.md schema reconciliation): old exports must always import (US-16).
// Both shapes rename imported grade scheme and level ids that collide with the built-in
// ids Migration 001 seeds (with a warning), so a crafted file can never upsert over a
// built-in grade row.

public let exportAppID = "cybersend"

/// A file that is not JSON or not a CyberSend export payload.
public struct ImportPayloadError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

extension ImportPayloadError: LocalizedError {
    public var errorDescription: String? { message }
}

/// A file created by a newer schema version than this build understands.
public struct ImportVersionError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

extension ImportVersionError: LocalizedError {
    public var errorDescription: String? { message }
}

/// A validated import payload in native column shape, plus any translation warnings.
public struct ParsedImportPayload: Equatable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: String
    /// True when the file used the legacy TypeScript column shape and was translated.
    public let legacyShape: Bool
    public let tables: [ExportTable: [ExportRow]]
    public let warnings: [String]

    public init(
        schemaVersion: Int,
        exportedAt: String,
        legacyShape: Bool,
        tables: [ExportTable: [ExportRow]],
        warnings: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.legacyShape = legacyShape
        self.tables = tables
        self.warnings = warnings
    }
}

// The exact plain-language messages of the TypeScript import service. US-16 requires
// plain-language errors and the ported tests assert them.
public let importInvalidJSONMessage = "The file is not valid JSON. Nothing was imported."
public let importInvalidPayloadMessage =
    "The file is not a valid CyberSend export (missing entity, bad value, or bad column). Nothing was imported."
public let importForeignKeyMessage = "The file contains rows that break foreign key links. Nothing was imported."

public func importNewerVersionMessage(fileVersion: Int, currentVersion: Int) -> String {
    "This file was created by a newer version of CyberSend (file schema \(fileVersion), this app runs schema \(currentVersion)). Update the app first. Nothing was imported."
}

public func importCannotUpgradeMessage(fileVersion: Int, targetVersion: Int) -> String {
    "This file uses schema version \(fileVersion), which this app cannot upgrade to version \(targetVersion). Nothing was imported."
}

// The exact plain-language message of the TypeScript revalidation after migration
// (src/features/backup/import_service.ts).
public let importMigratedInvalidMessage = "The migrated file is not valid. Nothing was imported."

// MARK: - Parsing

/// Parses and validates an export payload string. Throws ImportPayloadError on any
/// malformed input; never touches the database (US-16.1 and US-16.3: zero writes on
/// every failure path).
public func parseExportPayload(_ json: String) throws -> ParsedImportPayload {
    let raw: Any
    do {
        raw = try JSONSerialization.jsonObject(with: Data(json.utf8))
    } catch {
        throw ImportPayloadError(importInvalidJSONMessage)
    }
    guard let object = raw as? [String: Any] else {
        throw ImportPayloadError(importInvalidPayloadMessage)
    }
    // strictObject semantics: exactly these top level keys, no more, no fewer.
    let topLevelKeys = Set(object.keys)
    guard topLevelKeys == ["app", "schema_version", "exported_at", "tables"] else {
        throw ImportPayloadError(importInvalidPayloadMessage)
    }
    guard let app = object["app"] as? String, app == exportAppID else {
        throw ImportPayloadError(importInvalidPayloadMessage)
    }
    guard let schemaVersion = jsonInteger(object["schema_version"]), schemaVersion >= 1 else {
        throw ImportPayloadError(importInvalidPayloadMessage)
    }
    guard let exportedAt = object["exported_at"] as? String else {
        throw ImportPayloadError(importInvalidPayloadMessage)
    }
    guard let tables = object["tables"] as? [String: Any] else {
        throw ImportPayloadError(importInvalidPayloadMessage)
    }

    let nativeNames = Set(ExportTable.allCases.map(\.rawValue))
    let providedNames = Set(tables.keys)
    if providedNames == nativeNames {
        let parsed = try parseTables(tables, lookup: { ExportTable(rawValue: $0)?.spec })
        var nativeWarnings: [String] = []
        let guarded = renamingCollisionsInNativeGradeTables(parsed, warnings: &nativeWarnings)
        return ParsedImportPayload(
            schemaVersion: schemaVersion,
            exportedAt: exportedAt,
            legacyShape: false,
            tables: guarded,
            warnings: nativeWarnings
        )
    }
    if providedNames == Set(legacyTableNamesInInsertOrder) {
        let legacy = try parseTables(tables, lookup: { legacyExportTableSpecs[$0] })
        let translated = try translateLegacyTables(legacy, exportedAt: exportedAt)
        return ParsedImportPayload(
            schemaVersion: schemaVersion,
            exportedAt: exportedAt,
            legacyShape: true,
            tables: translated.tables,
            warnings: translated.warnings
        )
    }
    throw ImportPayloadError(importInvalidPayloadMessage)
}

/// Validates one object per table against the fixed column whitelist. strictObject
/// semantics: every column present, no unknown columns, exact scalar types, integers
/// only on integer columns, null only where the column is nullable.
private func parseTables(
    _ tables: [String: Any],
    lookup: (String) -> ExportTableSpec?
) throws -> [ExportTable: [ExportRow]] {
    var result: [ExportTable: [ExportRow]] = [:]
    for (name, rawRows) in tables {
        guard let table = ExportTable(rawValue: name), let spec = lookup(name) else {
            throw ImportPayloadError(importInvalidPayloadMessage)
        }
        guard let rows = rawRows as? [Any] else {
            throw ImportPayloadError(importInvalidPayloadMessage)
        }
        var parsedRows: [ExportRow] = []
        parsedRows.reserveCapacity(rows.count)
        for rawRow in rows {
            guard let rowObject = rawRow as? [String: Any] else {
                throw ImportPayloadError(importInvalidPayloadMessage)
            }
            parsedRows.append(try parseRow(rowObject, spec: spec))
        }
        result[table] = parsedRows
    }
    return result
}

private func parseRow(_ object: [String: Any], spec: ExportTableSpec) throws -> ExportRow {
    let expected = Set(spec.columnNames)
    guard Set(object.keys) == expected else {
        throw ImportPayloadError(importInvalidPayloadMessage)
    }
    var row: ExportRow = [:]
    row.reserveCapacity(spec.columns.count)
    for columnSpec in spec.columns {
        row[columnSpec.name] = try parseValue(object[columnSpec.name], column: columnSpec)
    }
    return row
}

private func parseValue(_ value: Any?, column: ExportColumn) throws -> ExportValue {
    guard let value, !(value is NSNull) else {
        if column.nullable { return .null }
        throw ImportPayloadError(importInvalidPayloadMessage)
    }
    switch column.type {
    case .text:
        guard let text = value as? String else {
            throw ImportPayloadError(importInvalidPayloadMessage)
        }
        return .text(text)
    case .integer:
        guard let number = value as? NSNumber, !isBooleanNumber(number) else {
            throw ImportPayloadError(importInvalidPayloadMessage)
        }
        let double = number.doubleValue
        guard double.isFinite,
              double.truncatingRemainder(dividingBy: 1) == 0,
              abs(double) < 9.2e18,
              let integer = Int64(exactly: double)
        else {
            throw ImportPayloadError(importInvalidPayloadMessage)
        }
        return .integer(integer)
    case .real:
        guard let number = value as? NSNumber, !isBooleanNumber(number) else {
            throw ImportPayloadError(importInvalidPayloadMessage)
        }
        let double = number.doubleValue
        guard double.isFinite else {
            throw ImportPayloadError(importInvalidPayloadMessage)
        }
        return .real(double)
    }
}

/// JSON booleans arrive as CFBoolean backed NSNumbers; zod's z.number() rejects them.
private func isBooleanNumber(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
}

/// Extracts an integer from a JSON value, rejecting booleans and fractions.
public func jsonInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, !isBooleanNumber(number) else { return nil }
    let double = number.doubleValue
    guard double.isFinite,
          double.truncatingRemainder(dividingBy: 1) == 0,
          let integer = Int(exactly: double)
    else { return nil }
    return integer
}

// MARK: - Post-migration revalidation

/// Strictly re-validates migrated rows against the table specs with the same
/// guarantees as the initial parse: exact column sets, exact value types, null only
/// where the column is nullable (port of the export_payload_schema.safeParse after
/// migrate_payload in src/features/backup/import_service.ts). Payload migrations are
/// arbitrary code over already parsed rows, so their output must pass the same checks
/// before it can reach the database; failures throw ImportPayloadError, keeping the
/// zero-writes guarantee of the import path.
public func validateMigratedPayload(_ payload: ParsedImportPayload) throws {
    guard payload.schemaVersion >= 1 else {
        throw ImportPayloadError(importMigratedInvalidMessage)
    }
    for (table, rows) in payload.tables {
        let spec = table.spec
        let expectedColumns = Set(spec.columnNames)
        for row in rows {
            guard Set(row.keys) == expectedColumns else {
                throw ImportPayloadError(importMigratedInvalidMessage)
            }
            for columnSpec in spec.columns {
                guard let value = row[columnSpec.name] else {
                    throw ImportPayloadError(importMigratedInvalidMessage)
                }
                switch value {
                case .null:
                    guard columnSpec.nullable else {
                        throw ImportPayloadError(importMigratedInvalidMessage)
                    }
                case .text:
                    guard columnSpec.type == .text else {
                        throw ImportPayloadError(importMigratedInvalidMessage)
                    }
                case .integer:
                    guard columnSpec.type == .integer else {
                        throw ImportPayloadError(importMigratedInvalidMessage)
                    }
                case .real:
                    guard columnSpec.type == .real else {
                        throw ImportPayloadError(importMigratedInvalidMessage)
                    }
                }
            }
        }
    }
}

// MARK: - Legacy translation

/// Reconciles a legacy TypeScript payload with docs/schema.sql (schema reconciliation
/// record in docs/decisions.md):
///
///  * gyms.is_active (1 = active) becomes gyms.is_archived (0 = active).
///  * climbs.grade_system and climbs.grade_raw become grade_system_id and grade_level_id,
///    resolved against built-in schemes plus any custom schemes found in the legacy
///  * grade.schemes settings row, which converts into grade_systems and grade_levels
///    rows and is then dropped (custom schemes are rows now, not settings JSON).
///  * holds.label becomes holds.role when it is a valid role, holds.color becomes
///    holds.color_family.
///  * attempts.fell_on_hold_id becomes fall_on_hold_id and attempts.created_at becomes
///    attempted_at.
private func translateLegacyTables(
    _ legacy: [ExportTable: [ExportRow]],
    exportedAt: String
) throws -> (tables: [ExportTable: [ExportRow]], warnings: [String]) {
    var warnings: [String] = []
    var tables: [ExportTable: [ExportRow]] = [:]

    // Custom schemes from the legacy settings table, converted to rows. Imported ids
    // that collide with built-in ids are renamed before any row is built: a crafted
    // legacy file claiming scheme id "v_scale" or level id "v4" would otherwise upsert
    // over the rows Migration 001 seeds, flipping is_builtin to 0 and relabeling the
    // built-in grades every climb displays against. The colliding entry is renamed
    // rather than skipped because its levels may hold genuine user data, and a custom
    // scheme that reuses a built-in id is still worth keeping under a fresh id: climbs
    // referencing the original id resolve against the built-in scheme below, so the
    // built-in meaning never changes and no distinct custom scheme is lost.
    let customSystems = legacyCustomSystems(in: legacy[.settings] ?? [], warnings: &warnings)
    let importedSystems = renamingCollisionsWithReservedIDs(customSystems, warnings: &warnings)
    tables[.gradeSystems] = importedSystems.map { system in
        [
            "id": .text(system.id),
            "name": .text(system.name),
            "is_builtin": .integer(0),
            "created_at": .text(exportedAt),
            "updated_at": .text(exportedAt),
        ]
    }
    var gradeLevelRows: [ExportRow] = []
    for system in importedSystems {
        for (index, level) in system.levels.enumerated() {
            gradeLevelRows.append([
                "id": .text(level.id),
                "system_id": .text(system.id),
                "label": .text(level.label),
                "rank_order": .integer(Int64(index)),
                "color_hex": .null,
            ])
        }
    }
    tables[.gradeLevels] = gradeLevelRows

    // Scheme and level resolution for climbs. Built-ins go in first, so the renamed
    // custom entries never shadow them: a climb referencing the original built-in id
    // resolves to the built-in scheme even when the file smuggled a custom entry with
    // that id.
    var systemsByID: [String: LegacySchemeResolution] = [:]
    for system in builtinGradeSystems {
        systemsByID[system.id] = LegacySchemeResolution(
            levelsByID: Dictionary(uniqueKeysWithValues: system.levels.map { ($0.id, $0.id) }),
            levelsByLabelLower: Dictionary(uniqueKeysWithValues: system.levels.map { ($0.label.lowercased(), $0.id) })
        )
    }
    for system in importedSystems {
        systemsByID[system.id] = LegacySchemeResolution(
            levelsByID: Dictionary(uniqueKeysWithValues: system.levels.map { ($0.id, $0.id) }),
            levelsByLabelLower: Dictionary(uniqueKeysWithValues: system.levels.map { ($0.label.lowercased(), $0.id) })
        )
    }

    tables[.gyms] = (legacy[.gyms] ?? []).map { row -> ExportRow in
        // 1 = active in the old schema; is_archived reads positively now.
        let isArchived: Int64 = (row["is_active"]?.integerValue ?? 1) == 1 ? 0 : 1
        return [
            "id": row["id"] ?? .null,
            "name": row["name"] ?? .null,
            "timezone": row["timezone"] ?? .null,
            "is_archived": .integer(isArchived),
            "created_at": row["created_at"] ?? .null,
            "updated_at": row["updated_at"] ?? .null,
        ]
    }

    tables[.climbs] = (legacy[.climbs] ?? []).map { row -> ExportRow in
        let climbID = row["id"]?.textValue ?? "unknown"
        let rawSystem = row["grade_system"]?.textValue ?? defaultGradeSystemID
        var systemID = rawSystem
        if systemsByID[rawSystem] == nil {
            warnings.append(
                "Climb \(climbID) references grade scheme '\(rawSystem)', which this app does not have. It imported as the default V scale."
            )
            systemID = defaultGradeSystemID
        }
        var levelID: String? = nil
        if let rawLevel = row["grade_raw"]?.textValue {
            levelID = resolveLegacyLevel(rawLevel, in: systemsByID[systemID])
            if levelID == nil {
                warnings.append(
                    "Climb \(climbID) references grade '\(rawLevel)', which does not exist in scheme '\(systemID)'. It imported without a grade level."
                )
            }
        }
        return [
            "id": row["id"] ?? .null,
            "gym_id": row["gym_id"] ?? .null,
            "wall_id": row["wall_id"] ?? .null,
            "board_id": row["board_id"] ?? .null,
            "board_problem_id": row["board_problem_id"] ?? .null,
            "name": row["name"] ?? .null,
            "grade_system_id": .text(systemID),
            "grade_level_id": levelID.map(ExportValue.text) ?? .null,
            "grade_norm": row["grade_norm"] ?? .null,
            "color_circuit": row["color_circuit"] ?? .null,
            "angle_deg": row["angle_deg"] ?? .null,
            "is_active": row["is_active"] ?? .null,
            "is_archived": row["is_archived"] ?? .null,
            "created_at": row["created_at"] ?? .null,
            "updated_at": row["updated_at"] ?? .null,
        ]
    }

    let validRoles: Set<String> = ["start", "intermediate", "top"]
    tables[.holds] = (legacy[.holds] ?? []).map { row -> ExportRow in
        var role: ExportValue = .null
        if let label = row["label"] {
            if case .text(let labelText) = label, validRoles.contains(labelText) {
                role = .text(labelText)
            } else if label != .null {
                warnings.append(
                    "A hold on climb \(row["climb_id"]?.textValue ?? "unknown") had label '\(label.textValue ?? "?")', which is not a start, intermediate, or top role. It imported without a role."
                )
            }
        }
        return [
            "id": row["id"] ?? .null,
            "climb_id": row["climb_id"] ?? .null,
            "x_norm": row["x_norm"] ?? .null,
            "y_norm": row["y_norm"] ?? .null,
            "radius_norm": row["radius_norm"] ?? .null,
            "role": role,
            "color_family": row["color"] ?? .null,
            "source": row["source"] ?? .null,
            "ordinal": row["ordinal"] ?? .null,
            "created_at": row["created_at"] ?? .null,
            "updated_at": row["updated_at"] ?? .null,
        ]
    }

    tables[.attempts] = (legacy[.attempts] ?? []).map { row -> ExportRow in
        [
            "id": row["id"] ?? .null,
            "session_id": row["session_id"] ?? .null,
            "climb_id": row["climb_id"] ?? .null,
            "attempt_no": row["attempt_no"] ?? .null,
            "outcome": row["outcome"] ?? .null,
            "fall_on_hold_id": row["fell_on_hold_id"] ?? .null,
            "video_id": row["video_id"] ?? .null,
            "notes": row["notes"] ?? .null,
            "attempted_at": row["created_at"] ?? .null,
        ]
    }

    tables[.settings] = (legacy[.settings] ?? []).filter {
        // The grade.schemes row converted into grade rows above; it is settings JSON of
        // the old schema and would be dead weight now.
        $0["key"]?.textValue != "grade.schemes"
    }

    for table in ExportTable.allCases where legacy[table] != nil {
        if tables[table] != nil { continue }
        tables[table] = legacy[table] ?? []
    }

    return (tables, warnings)
}

private struct LegacySchemeResolution {
    let levelsByID: [String: String]
    let levelsByLabelLower: [String: String]
}

private func resolveLegacyLevel(_ raw: String, in scheme: LegacySchemeResolution?) -> String? {
    guard let scheme else { return nil }
    if let byID = scheme.levelsByID[raw] { return byID }
    return scheme.levelsByLabelLower[raw.lowercased()]
}

private struct LegacyCustomSystem {
    let id: String
    let name: String
    let levels: [(id: String, label: String)]
}

/// Reads the legacy grade.schemes settings JSON (the TypeScript
/// encode_custom_systems shape: a list of {id, name, levels: [{id, label}]}).
/// Malformed data downgrades to a warning so old exports always import.
private func legacyCustomSystems(in settingsRows: [ExportRow], warnings: inout [String]) -> [LegacyCustomSystem] {
    guard let row = settingsRows.first(where: { $0["key"]?.textValue == "grade.schemes" }),
          case .text(let json) = row["value_json"] ?? .null
    else {
        return []
    }
    guard let data = json.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data),
          let list = parsed as? [Any]
    else {
        warnings.append("The file's custom grade schemes were not valid, so they were skipped.")
        return []
    }
    var systems: [LegacyCustomSystem] = []
    for entry in list {
        guard let object = entry as? [String: Any],
              let id = object["id"] as? String,
              let name = object["name"] as? String,
              let rawLevels = object["levels"] as? [Any]
        else {
            warnings.append("The file's custom grade schemes were malformed, so they were skipped.")
            return systems
        }
        var levels: [(id: String, label: String)] = []
        for rawLevel in rawLevels {
            guard let level = rawLevel as? [String: Any],
                  let levelID = level["id"] as? String,
                  let label = level["label"] as? String
            else {
                warnings.append("The file's custom grade scheme '\(id)' had a malformed level, so the scheme was skipped.")
                return systems
            }
            levels.append((id: levelID, label: label))
        }
        systems.append(LegacyCustomSystem(id: id, name: name, levels: levels))
    }
    warnings.append("Converted the file's custom grade schemes into grade scheme rows.")
    return systems
}

// MARK: - Reserved id collisions

/// Renames every imported scheme id and level id that collides with a reserved id:
/// the built-in ids seeded by Migration 001 (the canonical list lives in
/// Grade/BuiltinSchemes.swift) plus ids already taken earlier in the same file.
/// Built-ins always win; the imported entry keeps its data under an "_imported" id and
/// gets a plain-language warning. Renaming also guarantees ids stay unique across the
/// file, which the legacy resolution maps (built with Dictionary(uniqueKeysWithValues:))
/// rely on. The entry is never dropped, so a genuinely distinct custom scheme whose id
/// happens to collide survives the import instead of losing its levels.
private func renamingCollisionsWithReservedIDs(
    _ systems: [LegacyCustomSystem],
    warnings: inout [String]
) -> [LegacyCustomSystem] {
    var usedSystemIDs = builtinGradeSystemIDs
    var usedLevelIDs = builtinGradeLevelIDs
    var renamed: [LegacyCustomSystem] = []
    for system in systems {
        var systemID = system.id
        if usedSystemIDs.contains(systemID) {
            systemID = reservedVariantID(system.id, used: usedSystemIDs)
            if builtinGradeSystemIDs.contains(system.id) {
                warnings.append(
                    "The file declared a custom grade scheme with id '\(system.id)', which this app reserves for a built-in scheme, so it imported as '\(systemID)'. The built-in scheme was not changed."
                )
            } else {
                warnings.append(
                    "The file declared two grade schemes with id '\(system.id)', so the second one imported as '\(systemID)'."
                )
            }
        }
        usedSystemIDs.insert(systemID)
        var levels: [(id: String, label: String)] = []
        for level in system.levels {
            var levelID = level.id
            if usedLevelIDs.contains(levelID) {
                levelID = reservedVariantID(level.id, used: usedLevelIDs)
                if builtinGradeLevelIDs.contains(level.id) {
                    warnings.append(
                        "The file declared a grade level with id '\(level.id)', which this app reserves for a built-in grade level, so it imported as '\(levelID)'. The built-in grade level was not changed."
                    )
                } else {
                    warnings.append(
                        "The file declared two grade levels with id '\(level.id)' in scheme '\(system.id)', so the second one imported as '\(levelID)'."
                    )
                }
            }
            usedLevelIDs.insert(levelID)
            levels.append((id: levelID, label: level.label))
        }
        renamed.append(LegacyCustomSystem(id: systemID, name: system.name, levels: levels))
    }
    return renamed
}

/// A fresh id for a colliding import: "<id>_imported", numbered when even that is
/// already taken.
private func reservedVariantID(_ base: String, used: Set<String>) -> String {
    var candidate = base + "_imported"
    var attempt = 2
    while used.contains(candidate) {
        candidate = "\(base)_imported_\(attempt)"
        attempt += 1
    }
    return candidate
}

/// Applies the same built-in id collision guard to a native-shape payload. A crafted
/// native file could declare grade_systems id "v_scale" with is_builtin 0 and upsert
/// over the row Migration 001 seeds, flipping is_builtin and relabeling the built-in
/// grades every climb displays against. Native files carry their own grade rows, so
/// unlike legacy translation the guard cannot re-resolve climbs against built-ins:
/// renaming a declared row would break the file's foreign keys. Instead every
/// reference to a renamed row follows it (grade_levels.system_id and climbs
/// grade_system_id / grade_level_id), so the file's graph keeps its shape and the
/// renamed children land after their renamed parents in the FK safe upsert order.
/// Rows that claim built-in status (is_builtin 1) and levels sitting under their
/// canonical built-in scheme are re-exports of the rows Migration 001 seeds; they pass
/// through untouched so genuine exports round trip without warnings.
private func renamingCollisionsInNativeGradeTables(
    _ tables: [ExportTable: [ExportRow]],
    warnings: inout [String]
) -> [ExportTable: [ExportRow]] {
    var tables = tables
    // Original id to renamed id, recorded only when the first row claiming an id was
    // renamed, so later duplicate rows never steal references meant for the first.
    var systemRenames: [String: String] = [:]
    var levelRenames: [String: String] = [:]

    var usedSystemIDs = builtinGradeSystemIDs
    tables[.gradeSystems] = (tables[.gradeSystems] ?? []).map { row in
        let originalID = row["id"]?.textValue ?? ""
        let builtinClaim = builtinGradeSystemIDs.contains(originalID)
            && row["is_builtin"]?.integerValue == 1
        guard usedSystemIDs.contains(originalID), !builtinClaim else {
            usedSystemIDs.insert(originalID)
            return row
        }
        let renamed = reservedVariantID(originalID, used: usedSystemIDs)
        if builtinGradeSystemIDs.contains(originalID) {
            warnings.append(
                "The file declared a custom grade scheme with id '\(originalID)', which this app reserves for a built-in scheme, so it imported as '\(renamed)'. The built-in scheme was not changed."
            )
        } else {
            warnings.append(
                "The file declared two grade schemes with id '\(originalID)', so the second one imported as '\(renamed)'."
            )
        }
        if systemRenames[originalID] == nil {
            systemRenames[originalID] = renamed
        }
        usedSystemIDs.insert(renamed)
        var copy = row
        copy["id"] = .text(renamed)
        return copy
    }

    // A built-in level re-exports under its canonical scheme; the same id under any
    // other scheme (including a renamed collision) is imported data.
    let builtinLevelOwners = Dictionary(uniqueKeysWithValues: builtinGradeSystems.flatMap { system in
        system.levels.map { ($0.id, system.id) }
    })
    var usedLevelIDs = builtinGradeLevelIDs
    tables[.gradeLevels] = (tables[.gradeLevels] ?? []).map { row in
        var copy = row
        if let originalSystem = copy["system_id"]?.textValue,
           let renamedSystem = systemRenames[originalSystem] {
            copy["system_id"] = .text(renamedSystem)
        }
        let originalID = copy["id"]?.textValue ?? ""
        let owningSystem = copy["system_id"]?.textValue ?? ""
        let builtinClaim = builtinLevelOwners[originalID] == owningSystem
        guard usedLevelIDs.contains(originalID), !builtinClaim else {
            usedLevelIDs.insert(originalID)
            return copy
        }
        let renamed = reservedVariantID(originalID, used: usedLevelIDs)
        if builtinGradeLevelIDs.contains(originalID) {
            warnings.append(
                "The file declared a grade level with id '\(originalID)', which this app reserves for a built-in grade level, so it imported as '\(renamed)'. The built-in grade level was not changed."
            )
        } else {
            warnings.append(
                "The file declared two grade levels with id '\(originalID)' in scheme '\(owningSystem)', so the second one imported as '\(renamed)'."
            )
        }
        if levelRenames[originalID] == nil {
            levelRenames[originalID] = renamed
        }
        usedLevelIDs.insert(renamed)
        copy["id"] = .text(renamed)
        return copy
    }

    guard !systemRenames.isEmpty || !levelRenames.isEmpty else { return tables }

    tables[.climbs] = (tables[.climbs] ?? []).map { row in
        var copy = row
        if let originalSystem = copy["grade_system_id"]?.textValue,
           let renamedSystem = systemRenames[originalSystem] {
            copy["grade_system_id"] = .text(renamedSystem)
        }
        if let originalLevel = copy["grade_level_id"]?.textValue,
           let renamedLevel = levelRenames[originalLevel] {
            copy["grade_level_id"] = .text(renamedLevel)
        }
        return copy
    }
    return tables
}
