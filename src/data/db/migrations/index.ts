// Ordered forward only migrations (docs/decisions.md 2026-10-19, ordered integer migrations).
// Each migration's up(tx) runs in one transaction, is recorded in schema_migrations, and mirrors
// PRAGMA user_version. There are no down migrations; restore from a backup is the rollback path.

import type { SqlExecutor } from '../executor';
import { now_iso } from '../../time';
import { with_transaction } from '../transaction';
import { initial_migration } from './001_initial';

export interface Migration {
  version: number;
  name: string;
  up(tx: SqlExecutor): Promise<void>;
}

export const ALL_MIGRATIONS: readonly Migration[] = [initial_migration];

export const CURRENT_SCHEMA_VERSION: number = Math.max(...ALL_MIGRATIONS.map((migration) => migration.version));

// Raised when the database schema is newer than this app build knows how to run (US-7.4).
export class DatabaseVersionError extends Error {
  constructor(
    readonly databaseVersion: number,
    readonly appVersion: number,
  ) {
    super(
      `This database was created by a newer version of CyberSend (schema ${databaseVersion}, this app runs schema ${appVersion}). Update the app, or restore a backup taken with this version.`,
    );
    this.name = 'DatabaseVersionError';
  }
}

export interface MigrationRunResult {
  applied: readonly number[];
  schemaVersion: number;
}

export async function read_schema_version(executor: SqlExecutor): Promise<number> {
  const result = await executor.execute('PRAGMA user_version');
  const value = result.rows[0]?.user_version ?? 0;
  return typeof value === 'bigint' ? Number(value) : Number(value ?? 0);
}

function assert_well_formed(migrations: readonly Migration[]): readonly Migration[] {
  const seen = new Set<number>();
  const sorted = [...migrations].sort((a, b) => a.version - b.version);
  for (const migration of sorted) {
    if (!Number.isInteger(migration.version) || migration.version < 1) {
      throw new Error(`Invalid migration version: ${migration.version}`);
    }
    if (seen.has(migration.version)) {
      throw new Error(`Duplicate migration version: ${migration.version}`);
    }
    seen.add(migration.version);
  }
  return sorted;
}

// Applies every migration with a version above the database's current PRAGMA user_version.
// migrations is injectable so tests can exercise failure rollback and populated DB upgrades
// against the same runner the app uses.
export async function run_pending_migrations(
  executor: SqlExecutor,
  migrations: readonly Migration[] = ALL_MIGRATIONS,
): Promise<MigrationRunResult> {
  const ordered = assert_well_formed(migrations);
  const latest = ordered.length === 0 ? 0 : (ordered[ordered.length - 1]?.version ?? 0);
  const user_version = await read_schema_version(executor);
  if (user_version > latest) {
    throw new DatabaseVersionError(user_version, latest);
  }

  const applied: number[] = [];
  for (const migration of ordered) {
    if (migration.version <= user_version) {
      continue;
    }
    await with_transaction(executor, async (tx) => {
      await migration.up(tx);
      await tx.execute(
        'INSERT OR REPLACE INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)',
        [migration.version, migration.name, now_iso()],
      );
      // PRAGMA does not accept bound parameters. The version is a validated integer from our own
      // migration list, never user input, so interpolation is safe.
      await tx.execute(`PRAGMA user_version = ${migration.version}`);
    });
    applied.push(migration.version);
  }

  return { applied, schemaVersion: Math.max(user_version, latest) };
}
