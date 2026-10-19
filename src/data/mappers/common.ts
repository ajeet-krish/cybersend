// Row accessors shared by the entity mappers. Row keys are snake_case column names exactly as
// SQLite returned them; domain fields are camelCase.

import type { SqlRow, SqlValue } from '../db/executor';

function missing(row: SqlRow, key: string, expected: string): never {
  throw new Error(`Expected ${expected} for column ${key}, got ${String(row[key])}`);
}

export function row_text(row: SqlRow, key: string): string {
  const value = row[key];
  if (typeof value === 'string') {
    return value;
  }
  return missing(row, key, 'text');
}

export function row_opt_text(row: SqlRow, key: string): string | null {
  const value = row[key];
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value === 'string') {
    return value;
  }
  return missing(row, key, 'text or null');
}

export function row_int(row: SqlRow, key: string): number {
  const value = row[key];
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value === 'bigint') {
    return Number(value);
  }
  return missing(row, key, 'integer');
}

export function row_opt_int(row: SqlRow, key: string): number | null {
  const value = row[key];
  if (value === null || value === undefined) {
    return null;
  }
  return row_int(row, key);
}

export function row_real(row: SqlRow, key: string): number {
  const value = row[key];
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value === 'bigint') {
    return Number(value);
  }
  return missing(row, key, 'real');
}

export function row_opt_real(row: SqlRow, key: string): number | null {
  const value = row[key];
  if (value === null || value === undefined) {
    return null;
  }
  return row_real(row, key);
}

export function row_bool(row: SqlRow, key: string): boolean {
  return row_int(row, key) !== 0;
}

export function db_bool(value: boolean): number {
  return value ? 1 : 0;
}

export function db_opt_text(value: string | null): string | null {
  return value;
}

export function db_opt_int(value: number | null): number | null {
  return value;
}

export function db_opt_real(value: number | null): number | null {
  return value;
}

// Normalizes any JSON safe value coming from an import into a bindable SqlValue.
export function db_json_value(value: unknown): SqlValue {
  if (value === null || typeof value === 'string' || typeof value === 'number') {
    return value;
  }
  throw new Error(`Value is not JSON safe for SQLite: ${String(value)}`);
}
