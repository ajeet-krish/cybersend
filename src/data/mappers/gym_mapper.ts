import type { Gym } from '../../domain/models/gym';
import type { SqlRow, SqlValue } from '../db/executor';
import { db_bool, row_bool, row_opt_text, row_text } from './common';

export function row_to_gym(row: SqlRow): Gym {
  return {
    id: row_text(row, 'id'),
    name: row_text(row, 'name'),
    timezone: row_opt_text(row, 'timezone'),
    isActive: row_bool(row, 'is_active'),
    createdAt: row_text(row, 'created_at'),
    updatedAt: row_text(row, 'updated_at'),
  };
}

export function gym_to_row(gym: Gym): Record<string, SqlValue> {
  return {
    id: gym.id,
    name: gym.name,
    timezone: gym.timezone,
    is_active: db_bool(gym.isActive),
    created_at: gym.createdAt,
    updated_at: gym.updatedAt,
  };
}
