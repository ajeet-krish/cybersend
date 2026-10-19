// Pragmas applied at connection open, per docs/architecture.md:
// foreign_keys ON, journal_mode WAL, busy_timeout 5000 ms.
// PRAGMA foreign_keys is a no-op inside a transaction, so it must run at open time, not in
// migrations.

import type { SqlExecutor } from './executor';

export const OPEN_PRAGMAS: readonly string[] = [
  'PRAGMA foreign_keys = ON',
  'PRAGMA journal_mode = WAL',
  'PRAGMA busy_timeout = 5000',
];

export async function apply_open_pragmas(executor: SqlExecutor): Promise<void> {
  for (const sql of OPEN_PRAGMAS) {
    await executor.execute(sql);
  }
}
