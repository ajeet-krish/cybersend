// Hold repository. Coordinates are normalized 0..1 and validated in the domain layer before any
// write (docs/decisions.md, normalized coordinates at the domain boundary).

import { DomainValidationError } from '../../domain/errors';
import type { Hold, HoldSource } from '../../domain/models/hold';
import { validate_hold_coords } from '../../domain/models/hold';
import type { SqlExecutor } from '../db/executor';
import { generate_id } from '../id';
import { hold_to_row, row_to_hold } from '../mappers';
import { row_text } from '../mappers/common';
import { now_iso } from '../time';

export const DEFAULT_HOLD_RADIUS_NORM = 0.02;

export interface CreateHoldInput {
  climbId: string;
  xNorm: number;
  yNorm: number;
  radiusNorm?: number;
  label?: string | null;
  color?: string | null;
  source?: HoldSource;
  ordinal?: number | null;
}

export interface UpdateHoldInput {
  xNorm?: number;
  yNorm?: number;
  radiusNorm?: number;
  label?: string | null;
  color?: string | null;
  ordinal?: number | null;
}

export class HoldRepository {
  private readonly executor: SqlExecutor;

  constructor(executor: SqlExecutor) {
    this.executor = executor;
  }

  async create(input: CreateHoldInput): Promise<Hold> {
    const radiusNorm = input.radiusNorm ?? DEFAULT_HOLD_RADIUS_NORM;
    validate_hold_coords(input.xNorm, input.yNorm, radiusNorm);
    const timestamp = now_iso();
    const hold: Hold = {
      id: generate_id(),
      climbId: input.climbId,
      xNorm: input.xNorm,
      yNorm: input.yNorm,
      radiusNorm,
      label: input.label ?? null,
      color: input.color ?? null,
      source: input.source ?? 'manual',
      ordinal: input.ordinal ?? null,
      createdAt: timestamp,
      updatedAt: timestamp,
    };
    const row = hold_to_row(hold);
    await this.executor.execute(
      `INSERT INTO holds (id, climb_id, x_norm, y_norm, radius_norm, label, color, source, ordinal, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      Object.values(row),
    );
    return hold;
  }

  async listByClimb(climbId: string): Promise<Hold[]> {
    const result = await this.executor
      .prepare('SELECT * FROM holds WHERE climb_id = ? ORDER BY ordinal IS NULL, ordinal, created_at')
      .all([climbId]);
    return result.map(row_to_hold);
  }

  async get(id: string): Promise<Hold | null> {
    const row = await this.executor.prepare('SELECT * FROM holds WHERE id = ?').get([id]);
    return row === null ? null : row_to_hold(row);
  }

  async update(id: string, patch: UpdateHoldInput): Promise<Hold> {
    const existing = await this.get(id);
    if (existing === null) {
      throw new DomainValidationError('hold_not_found', 'Hold not found.');
    }
    const hold: Hold = {
      ...existing,
      xNorm: patch.xNorm ?? existing.xNorm,
      yNorm: patch.yNorm ?? existing.yNorm,
      radiusNorm: patch.radiusNorm ?? existing.radiusNorm,
      label: patch.label === undefined ? existing.label : patch.label,
      color: patch.color === undefined ? existing.color : patch.color,
      ordinal: patch.ordinal === undefined ? existing.ordinal : patch.ordinal,
      updatedAt: now_iso(),
    };
    validate_hold_coords(hold.xNorm, hold.yNorm, hold.radiusNorm);
    await this.executor.execute(
      `UPDATE holds SET x_norm = ?, y_norm = ?, radius_norm = ?, label = ?, color = ?, ordinal = ?, updated_at = ?
       WHERE id = ?`,
      [hold.xNorm, hold.yNorm, hold.radiusNorm, hold.label, hold.color, hold.ordinal, hold.updatedAt, id],
    );
    return hold;
  }

  async idsForClimb(climbId: string): Promise<string[]> {
    const result = await this.executor.prepare('SELECT id FROM holds WHERE climb_id = ?').all([climbId]);
    return result.map((row) => row_text(row, 'id'));
  }

  async delete(id: string): Promise<void> {
    await this.executor.execute('DELETE FROM holds WHERE id = ?', [id]);
  }

  async deleteByClimb(climbId: string): Promise<void> {
    await this.executor.execute('DELETE FROM holds WHERE climb_id = ?', [climbId]);
  }
}
