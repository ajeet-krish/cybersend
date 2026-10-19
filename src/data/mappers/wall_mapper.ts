import type { Wall } from '../../domain/models/wall';
import type { SqlRow, SqlValue } from '../db/executor';
import { db_bool, row_bool, row_opt_real, row_opt_text, row_text } from './common';

export function row_to_wall(row: SqlRow): Wall {
  return {
    id: row_text(row, 'id'),
    gymId: row_text(row, 'gym_id'),
    name: row_opt_text(row, 'name'),
    angleDeg: row_opt_real(row, 'angle_deg'),
    angleLabel: row_opt_text(row, 'angle_label'),
    isActive: row_bool(row, 'is_active'),
    createdAt: row_text(row, 'created_at'),
    updatedAt: row_text(row, 'updated_at'),
  };
}

export function wall_to_row(wall: Wall): Record<string, SqlValue> {
  return {
    id: wall.id,
    gym_id: wall.gymId,
    name: wall.name,
    angle_deg: wall.angleDeg,
    angle_label: wall.angleLabel,
    is_active: db_bool(wall.isActive),
    created_at: wall.createdAt,
    updated_at: wall.updatedAt,
  };
}
