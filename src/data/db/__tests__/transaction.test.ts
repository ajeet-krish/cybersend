// Transaction helper tests: nesting joins the outer transaction, rollback on error at any depth,
// and executeBatch atomicity.

import { NodeSqliteExecutor } from '../node_sqlite_executor';
import { create_test_database } from '../testing';
import { with_transaction, transaction_depth } from '../transaction';
import type { SqlExecutor } from '../executor';

async function count_rows(executor: SqlExecutor): Promise<number> {
  const row = await executor.prepare('SELECT COUNT(*) AS n FROM settings').get();
  return row?.n === undefined || row.n === null ? 0 : Number(row.n);
}

describe('with_transaction', () => {
  test('commits on success and resets depth', async () => {
    const { executor } = await create_test_database();
    await with_transaction(executor, async (tx) => {
      expect(transaction_depth(tx)).toBe(1);
      await tx.execute('INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)', ['a', '1', 't']);
    });
    expect(transaction_depth(executor)).toBe(0);
    expect(await count_rows(executor)).toBe(1);
    await executor.close();
  });

  test('rolls back every write when the body throws', async () => {
    const { executor } = await create_test_database();
    await expect(
      with_transaction(executor, async (tx) => {
        await tx.execute('INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)', ['a', '1', 't']);
        await tx.execute('INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)', ['b', '2', 't']);
        throw new Error('boom');
      }),
    ).rejects.toThrow('boom');

    expect(await count_rows(executor)).toBe(0);
    expect(transaction_depth(executor)).toBe(0);

    // The executor is usable again after a rollback.
    await with_transaction(executor, async (tx) => {
      await tx.execute('INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)', ['c', '3', 't']);
    });
    expect(await count_rows(executor)).toBe(1);
    await executor.close();
  });

  test('nested calls join the outer transaction (one commit)', async () => {
    const { executor } = await create_test_database();
    await with_transaction(executor, async (outer_tx) => {
      await outer_tx.execute('INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)', ['a', '1', 't']);
      await with_transaction(outer_tx, async (inner_tx) => {
        expect(transaction_depth(inner_tx)).toBe(2);
        await inner_tx.execute('INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)', ['b', '2', 't']);
        // Inner calls never commit; only the outermost call does.
        expect(await count_rows(inner_tx)).toBe(2);
      });
      expect(transaction_depth(outer_tx)).toBe(1);
    });
    expect(await count_rows(executor)).toBe(2);
    await executor.close();
  });

  test('a nested failure rolls back the entire outer transaction', async () => {
    const { executor } = await create_test_database();
    await expect(
      with_transaction(executor, async (outer_tx) => {
        await outer_tx.execute('INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)', ['a', '1', 't']);
        await with_transaction(outer_tx, async (inner_tx) => {
          await inner_tx.execute('INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)', ['b', '2', 't']);
          throw new Error('inner boom');
        });
      }),
    ).rejects.toThrow('inner boom');
    expect(await count_rows(executor)).toBe(0);
    expect(transaction_depth(executor)).toBe(0);
    await executor.close();
  });
});

describe('executeBatch', () => {
  test('runs statements in order atomically', async () => {
    const { executor } = await create_test_database();
    await executor.executeBatch([
      { sql: 'INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)', params: ['a', '1', 't'] },
      { sql: 'INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)', params: ['b', '2', 't'] },
    ]);
    expect(await count_rows(executor)).toBe(2);
    await executor.close();
  });

  test('a failing batch rolls back every statement', async () => {
    const { executor } = await create_test_database();
    await expect(
      executor.executeBatch([
        { sql: 'INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)', params: ['a', '1', 't'] },
        { sql: 'INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)', params: ['a', 'duplicate key', 't'] },
      ]),
    ).rejects.toThrow();
    expect(await count_rows(executor)).toBe(0);
    await executor.close();
  });

  test('a batch inside an open transaction joins it and does not commit early', async () => {
    const executor = NodeSqliteExecutor.open();
    await with_transaction(executor, async (tx) => {
      await tx.executeBatch([{ sql: 'CREATE TABLE t (id TEXT PRIMARY KEY)' }]);
      // The batch must not have committed: a later rollback still removes the table.
      throw new Error('rollback after batch');
    }).catch(() => undefined);
    const row = await executor
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 't'")
      .get();
    expect(row).toBeNull();
    await executor.close();
  });
});
