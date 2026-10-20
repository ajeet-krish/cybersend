import Foundation

// Custom grade scheme construction (port of src/domain/grade/custom_schemes.ts). After the
// schema reconciliation, custom schemes are rows in grade_systems and grade_levels instead of
// settings JSON, so the encode/decode helpers of the TypeScript spec are gone and the
// repository persists what makeCustomSystem builds. Level ids stay deterministic from the
// system id and level index, so renaming a level keeps its id and appending new levels never
// renumbers existing ones (US-9).

/// Builds a custom system with deterministic level ids (systemId_l0, systemId_l1, and so on).
/// colorHexes, when provided, must match levelLabels length and carries the optional per-level
/// color from grade_levels.color_hex.
public func makeCustomSystem(
    systemId: String,
    name: String,
    levelLabels: [String],
    colorHexes: [String?] = []
) throws -> GradeSystem {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    guard !trimmedName.isEmpty else {
        throw DomainValidationError("grade_system_name_required", "A custom scheme needs a name.")
    }
    let trimmedLabels = levelLabels.map { $0.trimmingCharacters(in: .whitespaces) }
    guard !trimmedLabels.isEmpty, trimmedLabels.allSatisfy({ !$0.isEmpty }) else {
        throw DomainValidationError(
            "grade_system_levels_required",
            "A custom scheme needs at least one non empty level label, ordered low to high."
        )
    }
    guard Set(trimmedLabels).count == trimmedLabels.count else {
        throw DomainValidationError(
            "grade_system_duplicate_levels",
            "Level labels must be unique within a scheme."
        )
    }
    guard colorHexes.isEmpty || colorHexes.count == trimmedLabels.count else {
        throw DomainValidationError(
            "grade_system_color_count_mismatch",
            "Color count must match the number of level labels."
        )
    }
    let systemLevels = trimmedLabels.enumerated().map { index, label in
        GradeLevel(
            id: "\(systemId)_l\(index)",
            label: label,
            rankOrder: index,
            colorHex: colorHexes.isEmpty ? nil : colorHexes[index]
        )
    }
    return GradeSystem(id: systemId, name: trimmedName, isBuiltin: false, levels: systemLevels)
}
