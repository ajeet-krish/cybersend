// Dump repository: raw table dumps for backup export and validated upserts for import. This is
// still a repository, so the SQL stays inside src/data/repositories (US-13). Rows are JSON safe
// plain records (TEXT, INTEGER, REAL only; docs/schema.sql has no BLOB columns).

import {
  TABLE_COLUMNS,
  TABLES_IN_INSERT_ORDER,
  type ExportRow,
  type TableName,
} from '../../domain/validation/tables';
import type { SqlExecutor, SqlRow, SqlValue } from '../db/executor';
import { read_schema_version } from '../db/migrations';

export type TableDump = Record<TableName, ExportRow[]>;

export interface UpsertCounts {
  inserted: number;
  updated: number;
}

export type UpsertReport = Record<TableName, UpsertCounts>;

function to_export_value(value: SqlValue): string | number | null {
  if (value === null || typeof value === 'string' || typeof value === 'number') {
    return value;
  }
  if (typeof value === 'bigint') {
    return Number(value);
  }
  throw new Error('Dump failed: unsupported column value type in the database.');
}

function to_export_row(row: SqlRow): ExportRow {
  const result: ExportRow = {};
  for (const [key, value] of Object.entries(row)) {
    result[key] = to_export_value(value);
  }
  return result;
}

function conflict_target(name: TableName): string {
  return name === 'settings' ? 'key' : 'id';
}

// Builds an upsert statement from the fixed column whitelist. Column names never come from
// imported data, only from TABLE_COLUMNS, so this is injection safe.
function upsert_sql(name: TableName): string {
  const columns = Object.keys(TABLE_COLUMNS[name]);
  const target = conflict_target(name);
  const updates = columns.filter((column) => column !== target).map((column) => `${column} = excluded.${column}`);
  return `INSERT INTO ${name} (${columns.join(', ')}) VALUES (${columns.map(() => '?').join(', ')})
    ON CONFLICT(${target}) DO UPDATE SET ${updates.join(', ')}`;
}

function select_conflict_sql(name: TableName): string {
  return `SELECT 1 AS present FROM ${name} WHERE ${conflict_target(name)} = ?`;
}

export class DumpRepository {
  private readonly executor: SqlExecutor;

  constructor(executor: SqlExecutor) {
    this.executor = executor;
  }

  async schemaVersion(): Promise<number> {
    return read_schema_version(this.executor);
  }

  async dumpAll(): Promise<TableDump> {
    const dump = {} as TableDump;
    for (const name of TABLES_IN_INSERT_ORDER) {
      const result = await this.executor.prepare(`SELECT * FROM ${name}`).all();
      dump[name] = result.map(to_export_row);
    }
    return dump;
  }

  // Upserts rows in FK safe order. The caller wraps this in a transaction so a failure anywhere
  // rolls back every table (zero partial writes).
  async upsertAll(tables: TableDump, tx: SqlExecutor = this.executor): Promise<UpsertReport> {
    const report = {} as UpsertReport;
    for (const name of TABLES_IN_INSERT_ORDER) {
      const counts: UpsertCounts = { inserted: 0, updated: 0 };
      const rows = tables[name] ?? [];
      const insert = tx.prepare(upsert_sql(name));
      const exists = tx.prepare(select_conflict_sql(name));
      const columns = Object.keys(TABLE_COLUMNS[name]);
      for (const row of rows) {
        const target = row[conflict_target(name)];
        const present = await exists.get([target ?? null]);
        if (present === null) {
          counts.inserted += 1;
        } else {
          counts.updated += 1;
        }
        await insert.run(columns.map((column) => row[column] ?? null));
      }
      report[name] = counts;
    }
    return report;
  }
}
