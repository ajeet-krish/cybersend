// Shared test support: hermetic in-memory databases through the node:sqlite adapter plus the
// real migration runner, exactly what repository tests need (docs/tests.md).

import { NodeSqliteExecutor } from './node_sqlite_executor';
import { run_pending_migrations } from './migrations';
import { create_repositories, type Repositories } from '../repositories';
import type { SqlExecutor } from './executor';

export interface TestDatabase {
  executor: SqlExecutor;
  repos: Repositories;
}

export async function create_test_database(): Promise<TestDatabase> {
  const executor = NodeSqliteExecutor.open();
  await run_pending_migrations(executor);
  return { executor, repos: create_repositories(executor) };
}
