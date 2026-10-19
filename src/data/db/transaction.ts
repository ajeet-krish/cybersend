// with_transaction: single transaction per call with nesting support via a depth counter.
// Nested calls on the same executor join the outer transaction and do not commit on their own,
// so multi table writes compose without savepoints. PRAGMA user_version writes roll back with
// the surrounding transaction, which keeps migrations and schema state consistent.

import type { SqlExecutor } from './executor';

const transaction_depths = new WeakMap<SqlExecutor, number>();

export function transaction_depth(executor: SqlExecutor): number {
  return transaction_depths.get(executor) ?? 0;
}

export async function with_transaction<T>(
  executor: SqlExecutor,
  fn: (tx: SqlExecutor) => Promise<T>,
): Promise<T> {
  const depth = transaction_depth(executor);
  if (depth > 0) {
    transaction_depths.set(executor, depth + 1);
    try {
      return await fn(executor);
    } finally {
      transaction_depths.set(executor, depth);
    }
  }

  // BEGIN IMMEDIATE takes the write lock up front so concurrent writers wait on busy_timeout
  // instead of failing late with SQLITE_BUSY on commit.
  transaction_depths.set(executor, 1);
  try {
    await executor.execute('BEGIN IMMEDIATE');
  } catch (error) {
    transaction_depths.delete(executor);
    throw error;
  }
  try {
    const result = await fn(executor);
    await executor.execute('COMMIT');
    return result;
  } catch (error) {
    try {
      await executor.execute('ROLLBACK');
    } catch {
      // The driver may have already rolled back. Keep the original error either way.
    }
    throw error;
  } finally {
    transaction_depths.delete(executor);
  }
}
