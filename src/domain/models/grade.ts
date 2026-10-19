// Grade scheme and level entities.
//
// Storage note: docs/schema.sql has no grade scheme tables. Built-in schemes (V scale, Font) live
// in src/domain/grade/builtin_schemes.ts; custom schemes live as ordered levels in the settings
// table under the key in src/domain/grade/custom_schemes.ts. Climbs reference a scheme by id in
// climbs.grade_system and a level by id in climbs.grade_raw, satisfying US-9 (scheme id plus level
// id, never a free string) without deviating from the authoritative schema.

export interface GradeLevel {
  id: string;
  label: string;
}

export interface GradeSystem {
  id: string;
  name: string;
  isBuiltin: boolean;
  levels: readonly GradeLevel[];
}

export interface ClimbGrade {
  schemeId: string;
  levelId: string;
}

export function climb_grade(gradeSystem: string, gradeRaw: string | null): ClimbGrade | null {
  if (gradeRaw === null) {
    return null;
  }
  return { schemeId: gradeSystem, levelId: gradeRaw };
}

export function find_level(system: GradeSystem, levelId: string): GradeLevel | null {
  return system.levels.find((level) => level.id === levelId) ?? null;
}

// Returns the level label for a (scheme, level) pair, or null when either is unknown.
export function grade_label(system: GradeSystem | null, levelId: string | null): string | null {
  if (!system || levelId === null) {
    return null;
  }
  return find_level(system, levelId)?.label ?? null;
}
