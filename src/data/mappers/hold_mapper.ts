import type { Hold, HoldSource } from '../../domain/models/hold';
import { HOLD_SOURCES } from '../../domain/models/hold';
import type { SqlRow, SqlValue } from '../db/executor';
import { row_opt_int, row_opt_text, row_real, row_text } from './common';

function parse_source(raw: string): HoldSource {
  if ((HOLD_SOURCES as readonly string[]).includes(raw)) {
    return raw as HoldSource;
  }
  throw new Error(`Unknown hold source in database: ${raw}`);
}

export function row_to_hold(row: SqlRow): Hold {
  return {
    id: row_text(row, 'id'),
    climbId: row_text(row, 'climb_id'),
    xNorm: row_real(row, 'x_norm'),
    yNorm: row_real(row, 'y_norm'),
    radiusNorm: row_real(row, 'radius_norm'),
    label: row_opt_text(row, 'label'),
    color: row_opt_text(row, 'color'),
    source: parse_source(row_text(row, 'source')),
    ordinal: row_opt_int(row, 'ordinal'),
    createdAt: row_text(row, 'created_at'),
    updatedAt: row_text(row, 'updated_at'),
  };
}

export function hold_to_row(hold: Hold): Record<string, SqlValue> {
  return {
    id: hold.id,
    climb_id: hold.climbId,
    x_norm: hold.xNorm,
    y_norm: hold.yNorm,
    radius_norm: hold.radiusNorm,
    label: hold.label,
    color: hold.color,
    source: hold.source,
    ordinal: hold.ordinal,
    created_at: hold.createdAt,
    updated_at: hold.updatedAt,
  };
}
