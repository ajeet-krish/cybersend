// Climb repository. Grades are stored as (grade_system, grade_raw) which hold the scheme id and
// the level id (never a free string); both are validated against the scheme before write. Note:
// requirements US-9 calls for normalized grade_scheme and grade_level tables, so this storage is
// pending reconciliation per docs/reviews.md (see src/data/db/migrations/001_initial.ts).
// Deleting a climb with attempts is blocked, archive is the only path (US-26).

import { DomainValidationError } from '../../domain/errors';
import { DEFAULT_GRADE_SYSTEM_ID } from '../../domain/grade/builtin_schemes';
import type { Climb } from '../../domain/models/climb';
import { is_climb_angle_valid } from '../../domain/models/climb';
import type { SqlExecutor } from '../db/executor';
import { generate_id } from '../id';
import { climb_to_row, row_to_climb } from '../mappers';
import { row_int } from '../mappers/common';
import { now_iso } from '../time';
import type { GradeRepository } from './grade_repository';

export interface CreateClimbInput {
  gymId: string;
  wallId?: string | null;
  name?: string | null;
  gradeSystem?: string;
  gradeRaw?: string | null;
  colorCircuit?: string | null;
  angleDeg?: number | null;
}

export interface UpdateClimbInput {
  wallId?: string | null;
  name?: string | null;
  gradeSystem?: string;
  gradeRaw?: string | null;
  colorCircuit?: string | null;
  angleDeg?: number | null;
}

export interface ListClimbsOptions {
  gymId?: string;
  includeArchived?: boolean;
  includeInactive?: boolean;
  limit?: number;
}

export class ClimbRepository {
  private readonly executor: SqlExecutor;
  private readonly grades: GradeRepository;

  constructor(executor: SqlExecutor, grades: GradeRepository) {
    this.executor = executor;
    this.grades = grades;
  }

  async create(input: CreateClimbInput): Promise<Climb> {
    await this.assert_gym_exists(input.gymId);
    const angleDeg = input.angleDeg ?? null;
    if (!is_climb_angle_valid(angleDeg)) {
      throw new DomainValidationError('climb_angle_out_of_range', 'Climb angle must be between 0 and 90 degrees.');
    }
    const gradeSystem = input.gradeSystem ?? DEFAULT_GRADE_SYSTEM_ID;
    const gradeRaw = input.gradeRaw ?? null;
    await this.grades.assertValidGrade(gradeSystem, gradeRaw);
    const timestamp = now_iso();
    const climb: Climb = {
      id: generate_id(),
      gymId: input.gymId,
      wallId: input.wallId ?? null,
      boardId: null,
      boardProblemId: null,
      name: input.name === undefined || input.name === null ? null : input.name.trim() || null,
      gradeSystem,
      gradeRaw,
      gradeNorm: null,
      colorCircuit: input.colorCircuit ?? null,
      angleDeg,
      isActive: true,
      isArchived: false,
      createdAt: timestamp,
      updatedAt: timestamp,
    };
    const row = climb_to_row(climb);
    // climb_to_row emits columns in the same order as the column list above.
    await this.executor.execute(
      `INSERT INTO climbs (id, gym_id, wall_id, board_id, board_problem_id, name, grade_system, grade_raw,
        grade_norm, color_circuit, angle_deg, is_active, is_archived, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      Object.values(row),
    );
    return climb;
  }

  async get(id: string): Promise<Climb | null> {
    const row = await this.executor.prepare('SELECT * FROM climbs WHERE id = ?').get([id]);
    return row === null ? null : row_to_climb(row);
  }

  async list(options: ListClimbsOptions = {}): Promise<Climb[]> {
    const clauses: string[] = [];
    const params: (string | number)[] = [];
    if (options.gymId !== undefined) {
      clauses.push('gym_id = ?');
      params.push(options.gymId);
    }
    if (!(options.includeArchived ?? false)) {
      clauses.push('is_archived = 0');
    }
    if (!(options.includeInactive ?? false)) {
      clauses.push('is_active = 1');
    }
    const where = clauses.length > 0 ? `WHERE ${clauses.join(' AND ')}` : '';
    const limit = options.limit === undefined ? '' : `LIMIT ${Math.max(0, Math.floor(options.limit))}`;
    const result = await this.executor
      .prepare(`SELECT * FROM climbs ${where} ORDER BY created_at DESC ${limit}`)
      .all(params);
    return result.map(row_to_climb);
  }

  async update(id: string, patch: UpdateClimbInput): Promise<Climb> {
    const existing = await this.get(id);
    if (existing === null) {
      throw new DomainValidationError('climb_not_found', 'Climb not found.');
    }
    const angleDeg = patch.angleDeg === undefined ? existing.angleDeg : patch.angleDeg;
    if (!is_climb_angle_valid(angleDeg)) {
      throw new DomainValidationError('climb_angle_out_of_range', 'Climb angle must be between 0 and 90 degrees.');
    }
    const gradeSystem = patch.gradeSystem ?? existing.gradeSystem;
    const gradeRaw = patch.gradeRaw === undefined ? existing.gradeRaw : patch.gradeRaw;
    await this.grades.assertValidGrade(gradeSystem, gradeRaw);
    const updated: Climb = {
      ...existing,
      wallId: patch.wallId === undefined ? existing.wallId : patch.wallId,
      name: patch.name === undefined ? existing.name : patch.name === null ? null : patch.name.trim() || null,
      gradeSystem,
      gradeRaw,
      colorCircuit: patch.colorCircuit === undefined ? existing.colorCircuit : patch.colorCircuit,
      angleDeg,
      updatedAt: now_iso(),
    };
    await this.executor.execute(
      `UPDATE climbs SET gym_id = ?, wall_id = ?, board_id = ?, board_problem_id = ?, name = ?, grade_system = ?,
        grade_raw = ?, grade_norm = ?, color_circuit = ?, angle_deg = ?, is_active = ?, is_archived = ?,
        updated_at = ? WHERE id = ?`,
      [
        updated.gymId, updated.wallId, updated.boardId, updated.boardProblemId, updated.name, updated.gradeSystem,
        updated.gradeRaw, updated.gradeNorm, updated.colorCircuit, updated.angleDeg, updated.isActive ? 1 : 0,
        updated.isArchived ? 1 : 0, updated.updatedAt, id,
      ],
    );
    return updated;
  }

  async archive(id: string): Promise<Climb> {
    return this.set_flag(id, 'is_archived', 1);
  }

  async unarchive(id: string): Promise<Climb> {
    return this.set_flag(id, 'is_archived', 0);
  }

  async setActive(id: string, isActive: boolean): Promise<Climb> {
    return this.set_flag(id, 'is_active', isActive ? 1 : 0);
  }

  // Blocked when attempts exist. US-26: fall data survives gym resets, archive only.
  async delete(id: string): Promise<void> {
    const attempts = await this.countAttempts(id);
    if (attempts > 0) {
      throw new DomainValidationError(
        'climb_has_attempts',
        `This climb has ${attempts} logged attempt${attempts === 1 ? '' : 's'}. Archive it instead of deleting.`,
      );
    }
    await this.executor.execute('DELETE FROM climbs WHERE id = ?', [id]);
  }

  async countAttempts(id: string): Promise<number> {
    const row = await this.executor.prepare('SELECT COUNT(*) AS n FROM attempts WHERE climb_id = ?').get([id]);
    return row === null ? 0 : row_int(row, 'n');
  }

  private async set_flag(id: string, column: 'is_archived' | 'is_active', value: 0 | 1): Promise<Climb> {
    const result = await this.executor.execute(
      `UPDATE climbs SET ${column} = ?, updated_at = ? WHERE id = ?`,
      [value, now_iso(), id],
    );
    if (result.rowsAffected === 0) {
      throw new DomainValidationError('climb_not_found', 'Climb not found.');
    }
    const climb = await this.get(id);
    if (climb === null) {
      throw new DomainValidationError('climb_not_found', 'Climb not found.');
    }
    return climb;
  }

  private async assert_gym_exists(gymId: string): Promise<void> {
    const row = await this.executor.prepare('SELECT id FROM gyms WHERE id = ?').get([gymId]);
    if (row === null) {
      throw new DomainValidationError('gym_not_found', 'Gym not found.');
    }
  }
}
