// Migration runner tests (US-7): empty database, populated database, forced failure rollback,
// and refusal of newer databases.

import { NodeSqliteExecutor } from '../node_sqlite_executor';
import { create_test_database } from '../testing';
import {
  ALL_MIGRATIONS,
  CURRENT_SCHEMA_VERSION,
  DatabaseVersionError,
  read_schema_version,
  run_pending_migrations,
  type Migration,
} from '../index';
import type { SqlExecutor } from '../executor';

async function table_names(executor: SqlExecutor): Promise<string[]> {
  const result = await executor.execute(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
  );
  return result.rows.map((row) => String(row.name));
}

describe('migrations from an empty database', () => {
  test('creates the full v1 schema and mirrors user_version', async () => {
    const executor = NodeSqliteExecutor.open();
    const result = await run_pending_migrations(executor);

    expect(result.applied).toEqual([1]);
    expect(await read_schema_version(executor)).toBe(CURRENT_SCHEMA_VERSION);

    const tables = await table_names(executor);
    expect(tables).toEqual([
      'attempts',
      'board_problems',
      'boards',
      'climbs',
      'grade_norm_params',
      'gyms',
      'holds',
      'photos',
      'pose_keypoints',
      'schema_migrations',
      'sessions',
      'settings',
      'videos',
      'walls',
    ]);

    const recorded = await executor.prepare('SELECT version, name FROM schema_migrations').all();
    expect(recorded).toEqual([{ version: 1, name: 'initial' }]);
    await executor.close();
  });

  test('is idempotent: a second run applies nothing', async () => {
    const executor = NodeSqliteExecutor.open();
    await run_pending_migrations(executor);
    const second = await run_pending_migrations(executor);

    expect(second.applied).toEqual([]);
    expect(await read_schema_version(executor)).toBe(1);
    const recorded = await executor.prepare('SELECT COUNT(*) AS n FROM schema_migrations').get();
    expect(recorded?.n).toBe(1);
    await executor.close();
  });

  test('every index from docs/schema.sql exists', async () => {
    const executor = NodeSqliteExecutor.open();
    await run_pending_migrations(executor);
    const result = await executor.execute(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%' ORDER BY name",
    );
    const indexes = result.rows.map((row) => String(row.name));
    expect(indexes).toEqual([
      'idx_attempts_climb',
      'idx_attempts_session',
      'idx_attempts_session_climb',
      'idx_climbs_gym',
      'idx_climbs_gym_status',
      'idx_gradenorm_scope',
      'idx_holds_climb',
      'idx_photos_climb',
      'idx_photos_session',
      'idx_pose_video_t',
      'idx_sessions_gym_started',
      'idx_videos_retention',
      'idx_videos_session',
      'idx_walls_gym',
    ]);
    await executor.close();
  });
});

describe('migrations on a populated database', () => {
  test('applies later migrations without losing data', async () => {
    const { executor, repos } = await create_test_database();
    const gym = await repos.gyms.create({ name: 'Boulder Garden' });
    const climb = await repos.climbs.create({ gymId: gym.id, name: 'Blue V4' });

    const adds_column: Migration = {
      version: 2,
      name: 'test_add_column',
      async up(tx) {
        await tx.execute('ALTER TABLE climbs ADD COLUMN nickname TEXT');
      },
    };
    const second = await run_pending_migrations(executor, [...ALL_MIGRATIONS, adds_column]);

    expect(second.applied).toEqual([2]);
    expect(await read_schema_version(executor)).toBe(2);
    const loaded = await repos.climbs.get(climb.id);
    expect(loaded?.name).toBe('Blue V4');
    const recorded = await executor.prepare('SELECT version FROM schema_migrations ORDER BY version').all();
    expect(recorded.map((row) => row.version)).toEqual([1, 2]);
    await executor.close();
  });
});

describe('migration failure handling', () => {
  test('a failing migration rolls back and leaves the prior schema intact', async () => {
    const executor = NodeSqliteExecutor.open();
    await run_pending_migrations(executor);

    const failing: Migration = {
      version: 2,
      name: 'test_failing',
      async up(tx) {
        await tx.execute('CREATE TABLE half_done (id TEXT PRIMARY KEY)');
        throw new Error('forced failure');
      },
    };

    await expect(run_pending_migrations(executor, [...ALL_MIGRATIONS, failing])).rejects.toThrow('forced failure');

    const tables = await table_names(executor);
    expect(tables).not.toContain('half_done');
    expect(await read_schema_version(executor)).toBe(1);
    const recorded = await executor.prepare('SELECT COUNT(*) AS n FROM schema_migrations').get();
    expect(recorded?.n).toBe(1);
    await executor.close();
  });

  test('a database newer than the app is refused with restore guidance (US-7.4)', async () => {
    const executor = NodeSqliteExecutor.open();
    await executor.execute('PRAGMA user_version = 99');

    await expect(run_pending_migrations(executor, ALL_MIGRATIONS)).rejects.toThrow(DatabaseVersionError);
    await expect(run_pending_migrations(executor, ALL_MIGRATIONS)).rejects.toThrow(/newer version/);
    await executor.close();
  });

  test('duplicate migration versions are rejected', async () => {
    const executor = NodeSqliteExecutor.open();
    const duplicate: Migration = { version: 1, name: 'dup', async up() {} };
    await expect(run_pending_migrations(executor, [...ALL_MIGRATIONS, duplicate])).rejects.toThrow(
      'Duplicate migration version',
    );
    await executor.close();
  });
});
