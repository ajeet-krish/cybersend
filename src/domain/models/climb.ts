// Climb entity. boardId and boardProblemId are dormant columns (board integration cut from the
// roadmap, docs/decisions.md) and stay null in Phases 0 to 5.

import { climb_grade, type ClimbGrade } from './grade';
import { is_angle_valid } from './wall';

export interface Climb {
  id: string;
  gymId: string;
  wallId: string | null;
  boardId: string | null;
  boardProblemId: string | null;
  name: string | null;
  // Scheme id. Part of the (scheme id, level id) pair; never a free string (US-9).
  gradeSystem: string;
  // Level id inside gradeSystem. Historically named grade_raw in docs/schema.sql.
  gradeRaw: string | null;
  gradeNorm: number | null;
  colorCircuit: string | null;
  angleDeg: number | null;
  isActive: boolean;
  isArchived: boolean;
  createdAt: string;
  updatedAt: string;
}

export function climb_grade_of(climb: Climb): ClimbGrade | null {
  return climb_grade(climb.gradeSystem, climb.gradeRaw);
}

// Quick-log shows active, non archived climbs only (US-10).
export function is_quick_loggable(climb: Climb): boolean {
  return climb.isActive && !climb.isArchived;
}

export function is_climb_angle_valid(angleDeg: number | null): boolean {
  return is_angle_valid(angleDeg);
}
