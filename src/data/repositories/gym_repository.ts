// Gym repository, the gym aggregate root. Gym archival uses gyms.is_active (docs/schema.sql;
// requirements US-8 calls it is_archived). Walls belong to the gym aggregate.

import { DomainValidationError } from '../../domain/errors';
import type { Gym } from '../../domain/models/gym';
import type { Wall } from '../../domain/models/wall';
import { is_angle_valid } from '../../domain/models/wall';
import type { SqlExecutor } from '../db/executor';
import { generate_id } from '../id';
import { row_to_gym, row_to_wall } from '../mappers';
import { now_iso } from '../time';

export interface CreateGymInput {
  name: string;
  timezone?: string | null;
}

export interface CreateWallInput {
  gymId: string;
  name?: string | null;
  angleDeg?: number | null;
  angleLabel?: string | null;
}

export class GymRepository {
  private readonly executor: SqlExecutor;

  constructor(executor: SqlExecutor) {
    this.executor = executor;
  }

  async create(input: CreateGymInput): Promise<Gym> {
    const name = input.name.trim();
    if (name === '') {
      throw new DomainValidationError('gym_name_required', 'A gym needs a name.');
    }
    const gym: Gym = {
      id: generate_id(),
      name,
      timezone: input.timezone ?? null,
      isActive: true,
      createdAt: now_iso(),
      updatedAt: now_iso(),
    };
    await this.executor.execute(
      'INSERT INTO gyms (id, name, timezone, is_active, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
      [gym.id, gym.name, gym.timezone, gym.isActive ? 1 : 0, gym.createdAt, gym.updatedAt],
    );
    return gym;
  }

  async get(id: string): Promise<Gym | null> {
    const row = await this.executor.prepare('SELECT * FROM gyms WHERE id = ?').get([id]);
    return row === null ? null : row_to_gym(row);
  }

  // Archived gyms are hidden from new session pickers by default but stay visible in history.
  async list(includeArchived = false): Promise<Gym[]> {
    const sql = includeArchived
      ? 'SELECT * FROM gyms ORDER BY name COLLATE NOCASE, created_at'
      : 'SELECT * FROM gyms WHERE is_active = 1 ORDER BY name COLLATE NOCASE, created_at';
    const result = await this.executor.prepare(sql).all();
    return result.map(row_to_gym);
  }

  async rename(id: string, name: string): Promise<Gym> {
    const trimmed = name.trim();
    if (trimmed === '') {
      throw new DomainValidationError('gym_name_required', 'A gym needs a name.');
    }
    const result = await this.executor.execute('UPDATE gyms SET name = ?, updated_at = ? WHERE id = ?', [
      trimmed,
      now_iso(),
      id,
    ]);
    if (result.rowsAffected === 0) {
      throw new DomainValidationError('gym_not_found', 'Gym not found.');
    }
    return this.require_gym(id);
  }

  async setActive(id: string, isActive: boolean): Promise<Gym> {
    const result = await this.executor.execute('UPDATE gyms SET is_active = ?, updated_at = ? WHERE id = ?', [
      isActive ? 1 : 0,
      now_iso(),
      id,
    ]);
    if (result.rowsAffected === 0) {
      throw new DomainValidationError('gym_not_found', 'Gym not found.');
    }
    return this.require_gym(id);
  }

  async archive(id: string): Promise<Gym> {
    return this.setActive(id, false);
  }

  async unarchive(id: string): Promise<Gym> {
    return this.setActive(id, true);
  }

  // Walls.

  async createWall(input: CreateWallInput): Promise<Wall> {
    if (!is_angle_valid(input.angleDeg ?? null)) {
      throw new DomainValidationError('wall_angle_out_of_range', 'Wall angle must be between 0 and 90 degrees.');
    }
    const wall: Wall = {
      id: generate_id(),
      gymId: input.gymId,
      name: input.name ?? null,
      angleDeg: input.angleDeg ?? null,
      angleLabel: input.angleLabel ?? null,
      isActive: true,
      createdAt: now_iso(),
      updatedAt: now_iso(),
    };
    await this.executor.execute(
      `INSERT INTO walls (id, gym_id, name, angle_deg, angle_label, is_active, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [wall.id, wall.gymId, wall.name, wall.angleDeg, wall.angleLabel, wall.isActive ? 1 : 0, wall.createdAt, wall.updatedAt],
    );
    return wall;
  }

  async listWalls(gymId: string, includeInactive = false): Promise<Wall[]> {
    const sql = includeInactive
      ? 'SELECT * FROM walls WHERE gym_id = ? ORDER BY name COLLATE NOCASE, created_at'
      : 'SELECT * FROM walls WHERE gym_id = ? AND is_active = 1 ORDER BY name COLLATE NOCASE, created_at';
    const result = await this.executor.prepare(sql).all([gymId]);
    return result.map(row_to_wall);
  }

  async setWallActive(id: string, isActive: boolean): Promise<void> {
    await this.executor.execute('UPDATE walls SET is_active = ?, updated_at = ? WHERE id = ?', [
      isActive ? 1 : 0,
      now_iso(),
      id,
    ]);
  }

  private async require_gym(id: string): Promise<Gym> {
    const gym = await this.get(id);
    if (gym === null) {
      throw new DomainValidationError('gym_not_found', 'Gym not found.');
    }
    return gym;
  }
}
