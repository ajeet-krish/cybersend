// Built-in grade schemes: V scale (primary, requirements decision 4) and Fontainebleau.
// Level ids are stable identifiers; labels are what the UI shows. Scales are ordered lists,
// lowest to highest.

import type { GradeLevel, GradeSystem } from '../models/grade';

function levels_from_labels(labels: readonly string[], id_of: (label: string, index: number) => string): readonly GradeLevel[] {
  return labels.map((label, index) => ({ id: id_of(label, index), label }));
}

const V_LABELS: readonly string[] = Array.from({ length: 18 }, (_unused, index) => `V${index}`);

export const V_SCALE: GradeSystem = {
  id: 'v_scale',
  name: 'V Scale',
  isBuiltin: true,
  levels: levels_from_labels(V_LABELS, (label) => label.toLowerCase()),
};

const FONT_LABELS: readonly string[] = [
  '1',
  '2',
  '3',
  '4',
  '4+',
  '5',
  '5+',
  '6a',
  '6a+',
  '6b',
  '6b+',
  '6c',
  '6c+',
  '7a',
  '7a+',
  '7b',
  '7b+',
  '7c',
  '7c+',
  '8a',
  '8a+',
  '8b',
  '8b+',
  '8c',
  '8c+',
  '9a',
];

function font_level_id(label: string): string {
  return `f${label.replace('+', '_plus')}`;
}

export const FONT_SCALE: GradeSystem = {
  id: 'font',
  name: 'Fontainebleau',
  isBuiltin: true,
  levels: levels_from_labels(FONT_LABELS, font_level_id),
};

export const BUILTIN_GRADE_SYSTEMS: readonly GradeSystem[] = [V_SCALE, FONT_SCALE];

export const DEFAULT_GRADE_SYSTEM_ID = V_SCALE.id;

export function find_builtin_system(systemId: string): GradeSystem | null {
  return BUILTIN_GRADE_SYSTEMS.find((system) => system.id === systemId) ?? null;
}
