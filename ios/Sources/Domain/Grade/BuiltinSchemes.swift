import Foundation

// Built-in grade schemes: V scale (primary, requirements decision 4) and Fontainebleau
// (port of src/domain/grade/builtin_schemes.ts). Level ids are stable identifiers (the same
// ids seeded into grade_levels by Migration 001); labels are what the UI shows. Scales are
// ordered lists, lowest to highest.

private func levels(from labels: [String], idOf: (String, Int) -> String) -> [GradeLevel] {
    labels.enumerated().map { index, label in
        GradeLevel(id: idOf(label, index), label: label, rankOrder: index)
    }
}

private let vLabels: [String] = (0..<18).map { "V\($0)" }

public let vScale: GradeSystem = GradeSystem(
    id: "v_scale",
    name: "V Scale",
    isBuiltin: true,
    levels: levels(from: vLabels) { label, _ in label.lowercased() }
)

private let fontLabels: [String] = [
    "1", "2", "3", "4", "4+", "5", "5+",
    "6a", "6a+", "6b", "6b+", "6c", "6c+",
    "7a", "7a+", "7b", "7b+", "7c", "7c+",
    "8a", "8a+", "8b", "8b+", "8c", "8c+", "9a",
]

private func fontLevelID(_ label: String) -> String {
    "f" + label.replacingOccurrences(of: "+", with: "_plus")
}

public let fontScale: GradeSystem = GradeSystem(
    id: "font",
    name: "Fontainebleau",
    isBuiltin: true,
    levels: levels(from: fontLabels) { label, _ in fontLevelID(label) }
)

public let builtinGradeSystems: [GradeSystem] = [vScale, fontScale]

/// Every built-in scheme id. This is the canonical list: Migration 001 seeds the same
/// ids from SQL (see Sources/Data/Database/Migration001.swift, which points back here).
/// Import paths check against it so an imported id can never overwrite a built-in row.
public let builtinGradeSystemIDs: Set<String> = Set(builtinGradeSystems.map(\.id))

/// Every built-in level id across all built-in schemes (v0 through v17, f1 through
/// f9a). Level ids are global primary keys in grade_levels, so imports must treat the
/// whole set as reserved too.
public let builtinGradeLevelIDs: Set<String> = Set(builtinGradeSystems.flatMap { $0.levels.map(\.id) })

public let defaultGradeSystemID: String = vScale.id

public func findBuiltinSystem(_ systemId: String) -> GradeSystem? {
    builtinGradeSystems.first { $0.id == systemId }
}
