// Settings repository. Values are JSON text; keys are stable snake_case identifiers from
// src/domain/models/settings.ts.

import { DomainValidationError } from '../../domain/errors';
import type { SettingEntry } from '../../domain/models/settings';
import type { SqlExecutor } from '../db/executor';
import { row_text } from '../mappers/common';
import { now_iso } from '../time';

export class SettingsRepository {
  private readonly executor: SqlExecutor;

  constructor(executor: SqlExecutor) {
    this.executor = executor;
  }

  async get(key: string): Promise<string | null> {
    const row = await this.executor.prepare('SELECT value_json FROM settings WHERE key = ?').get([key]);
    return row === null ? null : row_text(row, 'value_json');
  }

  async getJson<T>(key: string): Promise<T | null> {
    const raw = await this.get(key);
    if (raw === null) {
      return null;
    }
    try {
      return JSON.parse(raw) as T;
    } catch {
      throw new DomainValidationError('settings_corrupt', `Stored value for ${key} is not valid JSON.`);
    }
  }

  async set(key: string, valueJson: string): Promise<void> {
    await this.executor.execute(
      `INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at`,
      [key, valueJson, now_iso()],
    );
  }

  async setJson(key: string, value: unknown): Promise<void> {
    await this.set(key, JSON.stringify(value));
  }

  async remove(key: string): Promise<void> {
    await this.executor.execute('DELETE FROM settings WHERE key = ?', [key]);
  }

  async list(): Promise<SettingEntry[]> {
    const result = await this.executor.prepare('SELECT key, value_json, updated_at FROM settings ORDER BY key').all();
    return result.map((row) => ({
      key: row_text(row, 'key'),
      valueJson: row_text(row, 'value_json'),
      updatedAt: row_text(row, 'updated_at'),
    }));
  }
}
