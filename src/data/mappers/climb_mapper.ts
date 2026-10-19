import type { Climb } from '../../domain/models/climb';
import type { SqlRow, SqlValue } from '../db/executor';
import { db_bool, row_bool, row_opt_real, row_opt_text, row_text } from './common';

export function row_to_climb(row: SqlRow): Climb {
  return {
    id: row_text(row, 'id'),
    gymId: row_text(row, 'gym_id'),
    wallId: row_opt_text(row, 'wall_id'),
    boardId: row_opt_text(row, 'board_id'),
    boardProblemId: row_opt_text(row, 'board_problem_id'),
    name: row_opt_text(row, 'name'),
    gradeSystem: row_text(row, 'grade_system'),
    gradeRaw: row_opt_text(row, 'grade_raw'),
    gradeNorm: row_opt_real(row, 'grade_norm'),
    colorCircuit: row_opt_text(row, 'color_circuit'),
    angleDeg: row_opt_real(row, 'angle_deg'),
    isActive: row_bool(row, 'is_active'),
    isArchived: row_bool(row, 'is_archived'),
    createdAt: row_text(row, 'created_at'),
    updatedAt: row_text(row, 'updated_at'),
  };
}

export function climb_to_row(climb: Climb): Record<string, SqlValue> {
  return {
    id: climb.id,
    gym_id: climb.gymId,
    wall_id: climb.wallId,
    board_id: climb.boardId,
    board_problem_id: climb.boardProblemId,
    name: climb.name,
    grade_system: climb.gradeSystem,
    grade_raw: climb.gradeRaw,
    grade_norm: climb.gradeNorm,
    color_circuit: climb.colorCircuit,
    angle_deg: climb.angleDeg,
    is_active: db_bool(climb.isActive),
    is_archived: db_bool(climb.isArchived),
    created_at: climb.createdAt,
    updated_at: climb.updatedAt,
  };
}
