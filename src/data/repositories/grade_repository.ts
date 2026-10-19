// Grade repository. Built-in schemes (V scale, Font) live in domain code; custom schemes live as
// ordered levels in the settings table because docs/schema.sql has no scheme tables. Deleting a
// scheme in use is blocked (US-9).

import { DomainValidationError } from '../../domain/errors';
import { BUILTIN_GRADE_SYSTEMS, DEFAULT_GRADE_SYSTEM_ID } from '../../domain/grade/builtin_schemes';
import { decode_custom_systems, encode_custom_systems, make_custom_system } from '../../domain/grade/custom_schemes';
import type { GradeSystem } from '../../domain/models/grade';
import { find_level } from '../../domain/models/grade';
import {
  SETTINGS_KEY_DEFAULT_GRADE_SYSTEM,
  SETTINGS_KEY_GRADE_SCHEMES,
} from '../../domain/models/settings';
import type { SqlExecutor } from '../db/executor';
import { generate_id } from '../id';
import { row_int, row_text } from '../mappers/common';
import { now_iso } from '../time';

export interface CreateGradeSystemInput {
  name: string;
  levelLabels: readonly string[];
}

export class GradeRepository {
  private readonly executor: SqlExecutor;

  constructor(executor: SqlExecutor) {
    this.executor = executor;
  }

  async listSystems(): Promise<GradeSystem[]> {
    const custom = await this.custom_systems();
    return [...BUILTIN_GRADE_SYSTEMS, ...custom];
  }

  async getSystem(systemId: string): Promise<GradeSystem | null> {
    const builtin = BUILTIN_GRADE_SYSTEMS.find((system) => system.id === systemId) ?? null;
    if (builtin !== null) {
      return builtin;
    }
    const custom = await this.custom_systems();
    return custom.find((system) => system.id === systemId) ?? null;
  }

  async createCustomSystem(input: CreateGradeSystemInput): Promise<GradeSystem> {
    const system = make_custom_system(generate_id(), input.name, input.levelLabels);
    const existing = await this.custom_systems();
    await this.save_custom_systems([...existing, system]);
    return system;
  }

  async renameCustomSystem(systemId: string, name: string): Promise<GradeSystem> {
    const trimmed = name.trim();
    if (trimmed === '') {
      throw new DomainValidationError('grade_system_name_required', 'A custom scheme needs a name.');
    }
    const existing = await this.custom_systems();
    const target = existing.find((system) => system.id === systemId);
    if (!target) {
      throw new DomainValidationError(
        'grade_system_not_found',
        BUILTIN_GRADE_SYSTEMS.some((system) => system.id === systemId)
          ? 'Built-in schemes cannot be renamed.'
          : 'Custom scheme not found.',
      );
    }
    const renamed: GradeSystem = { ...target, name: trimmed };
    await this.save_custom_systems(existing.map((system) => (system.id === systemId ? renamed : system)));
    return renamed;
  }

  async deleteCustomSystem(systemId: string): Promise<void> {
    if (BUILTIN_GRADE_SYSTEMS.some((system) => system.id === systemId)) {
      throw new DomainValidationError('cannot_delete_builtin_scheme', 'Built-in grade schemes cannot be deleted.');
    }
    const in_use = await this.count_climbs_using(systemId);
    if (in_use > 0) {
      throw new DomainValidationError(
        'grade_system_in_use',
        `This scheme is used by ${in_use} climb${in_use === 1 ? '' : 's'}. Re-grade those climbs first.`,
      );
    }
    const existing = await this.custom_systems();
    if (!existing.some((system) => system.id === systemId)) {
      throw new DomainValidationError('grade_system_not_found', 'Custom scheme not found.');
    }
    await this.save_custom_systems(existing.filter((system) => system.id !== systemId));
    const default_id = await this.getDefaultSystemId();
    if (default_id === systemId) {
      await this.executor.execute('DELETE FROM settings WHERE key = ?', [SETTINGS_KEY_DEFAULT_GRADE_SYSTEM]);
    }
  }

  async setDefaultSystem(systemId: string): Promise<void> {
    const system = await this.getSystem(systemId);
    if (system === null) {
      throw new DomainValidationError('grade_system_not_found', 'Grade scheme not found.');
    }
    await this.executor.execute(
      `INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at`,
      [SETTINGS_KEY_DEFAULT_GRADE_SYSTEM, JSON.stringify(systemId), now_iso()],
    );
  }

  async getDefaultSystemId(): Promise<string> {
    const row = await this.executor
      .prepare('SELECT value_json FROM settings WHERE key = ?')
      .get([SETTINGS_KEY_DEFAULT_GRADE_SYSTEM]);
    if (row === null) {
      return DEFAULT_GRADE_SYSTEM_ID;
    }
    try {
      const parsed: unknown = JSON.parse(row_text(row, 'value_json'));
      return typeof parsed === 'string' ? parsed : DEFAULT_GRADE_SYSTEM_ID;
    } catch {
      return DEFAULT_GRADE_SYSTEM_ID;
    }
  }

  // Throws unless (systemId, levelId) names a known level. A null levelId clears the grade and
  // is always valid.
  async assertValidGrade(systemId: string, levelId: string | null): Promise<void> {
    if (levelId === null) {
      return;
    }
    const system = await this.getSystem(systemId);
    if (system === null) {
      throw new DomainValidationError('grade_system_not_found', `Unknown grade scheme: ${systemId}`);
    }
    if (find_level(system, levelId) === null) {
      throw new DomainValidationError(
        'grade_level_not_in_scheme',
        `Level ${levelId} does not exist in scheme ${system.name}.`,
      );
    }
  }

  private async custom_systems(): Promise<GradeSystem[]> {
    const row = await this.executor
      .prepare('SELECT value_json FROM settings WHERE key = ?')
      .get([SETTINGS_KEY_GRADE_SCHEMES]);
    return decode_custom_systems(row === null ? null : row_text(row, 'value_json'));
  }

  private async save_custom_systems(systems: readonly GradeSystem[]): Promise<void> {
    await this.executor.execute(
      `INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at`,
      [SETTINGS_KEY_GRADE_SCHEMES, encode_custom_systems(systems), now_iso()],
    );
  }

  private async count_climbs_using(systemId: string): Promise<number> {
    const row = await this.executor.prepare('SELECT COUNT(*) AS n FROM climbs WHERE grade_system = ?').get([systemId]);
    return row === null ? 0 : row_int(row, 'n');
  }
}
