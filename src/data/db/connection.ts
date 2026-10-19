// Device database connection: op-sqlite open with the standard pragmas plus migrations, wrapped
// in the SqlExecutor port. The native module loads lazily so environments without it (Expo Go)
// get a clear error instead of a crash; screens render an error screen via the providers.

import type { DB } from '@op-engineering/op-sqlite';

import { run_pending_migrations, type MigrationRunResult } from './migrations';
import type { SqlExecutor } from './executor';
import { OpSqliteExecutor } from './op_sqlite_executor';
import { apply_open_pragmas } from './pragmas';

export const DATABASE_FILENAME = 'cybersend.sqlite';
export const DATABASE_DIRECTORY = 'db';

export class DatabaseUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DatabaseUnavailableError';
  }
}

interface OpSqliteModule {
  open: (options: { name: string; location?: string }) => DB;
}

declare const require: (id: string) => unknown;

function load_op_sqlite(): OpSqliteModule {
  try {
    return require('@op-engineering/op-sqlite') as OpSqliteModule;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new DatabaseUnavailableError(
      `The on device database module is unavailable. CyberSend logging needs a development build (npx expo run:ios). Expo Go cannot open the database. Details: ${message}`,
    );
  }
}

export interface OpenDatabaseResult {
  executor: SqlExecutor;
  migration: MigrationRunResult;
}

export async function open_device_database(filename = DATABASE_FILENAME): Promise<OpenDatabaseResult> {
  const op_sqlite = load_op_sqlite();
  let db: DB;
  try {
    db = op_sqlite.open({ name: filename, location: DATABASE_DIRECTORY });
  } catch {
    // Fall back to the driver default location when the db directory cannot be created.
    db = op_sqlite.open({ name: filename });
  }
  const executor = new OpSqliteExecutor(db);
  try {
    await apply_open_pragmas(executor);
    const migration = await run_pending_migrations(executor);
    return { executor, migration };
  } catch (error) {
    await executor.close().catch(() => undefined);
    throw error;
  }
}
