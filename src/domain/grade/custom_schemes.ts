// Custom grade schemes are stored as ordered levels in the settings table (key
// SETTINGS_KEY_GRADE_SCHEMES) because docs/schema.sql has no scheme tables. Level ids are
// deterministic from the system id and level index, so renaming a level keeps its id stable and
// appending new levels never renumbers existing ones (US-9).

import { DomainValidationError } from '../errors';
import type { GradeLevel, GradeSystem } from '../models/grade';

function is_record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function parse_level(raw: unknown, system_id: string): GradeLevel {
  if (!is_record(raw)) {
    throw new DomainValidationError(
      'grade_schemes_corrupt',
      `Custom scheme ${system_id} has a malformed level entry.`,
    );
  }
  const { id, label } = raw;
  if (typeof id !== 'string' || typeof label !== 'string') {
    throw new DomainValidationError(
      'grade_schemes_corrupt',
      `Custom scheme ${system_id} has a malformed level entry.`,
    );
  }
  return { id, label };
}

function parse_system(raw: unknown): GradeSystem {
  if (!is_record(raw)) {
    throw new DomainValidationError('grade_schemes_corrupt', 'Custom scheme list has a malformed entry.');
  }
  const { id, name, levels } = raw;
  if (typeof id !== 'string' || typeof name !== 'string' || !Array.isArray(levels)) {
    throw new DomainValidationError('grade_schemes_corrupt', 'Custom scheme list has a malformed entry.');
  }
  return {
    id,
    name,
    isBuiltin: false,
    levels: levels.map((level) => parse_level(level, id)),
  };
}

export function decode_custom_systems(json: string | null): GradeSystem[] {
  if (json === null || json === '') {
    return [];
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new DomainValidationError('grade_schemes_corrupt', 'Stored custom grade schemes are not valid JSON.');
  }
  if (!Array.isArray(parsed)) {
    throw new DomainValidationError('grade_schemes_corrupt', 'Stored custom grade schemes must be a list.');
  }
  return parsed.map(parse_system);
}

export function encode_custom_systems(systems: readonly GradeSystem[]): string {
  const plain = systems
    .filter((system) => !system.isBuiltin)
    .map((system) => ({
      id: system.id,
      name: system.name,
      levels: system.levels.map((level) => ({ id: level.id, label: level.label })),
    }));
  return JSON.stringify(plain);
}

export function make_custom_system(systemId: string, name: string, levelLabels: readonly string[]): GradeSystem {
  const trimmed_name = name.trim();
  if (trimmed_name === '') {
    throw new DomainValidationError('grade_system_name_required', 'A custom scheme needs a name.');
  }
  const trimmed_labels = levelLabels.map((label) => label.trim());
  if (trimmed_labels.length === 0 || trimmed_labels.some((label) => label === '')) {
    throw new DomainValidationError(
      'grade_system_levels_required',
      'A custom scheme needs at least one non empty level label, ordered low to high.',
    );
  }
  if (new Set(trimmed_labels).size !== trimmed_labels.length) {
    throw new DomainValidationError('grade_system_duplicate_levels', 'Level labels must be unique within a scheme.');
  }
  return {
    id: systemId,
    name: trimmed_name,
    isBuiltin: false,
    levels: trimmed_labels.map((label, index) => ({ id: `${systemId}_l${index}`, label })),
  };
}
