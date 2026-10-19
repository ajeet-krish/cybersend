// node:sqlite adapter for the SqlExecutor port. Used only by Jest tests (and any future Node
// tooling) so repository and migration tests are hermetic without a simulator. The app never
// imports this module; the device uses src/data/db/op_sqlite_executor.ts instead.
//
// node:sqlite is built into Node 22.5+ (this project runs Node 26). The module is required lazily
// with structural types because the app type environment intentionally excludes @types/node.

import { OPEN_PRAGMAS } from './pragmas';
import type {
  PreparedStatement,
  ResultSet,
  SqlExecutor,
  SqlParams,
  SqlRow,
  SqlStatement,
  SqlValue,
} from './executor';
import { with_transaction } from './transaction';

interface NodeSqliteStatement {
  run(...params: unknown[]): { changes: number | bigint; lastInsertRowid: number | bigint };
  all(...params: unknown[]): Record<string, unknown>[];
  get(...params: unknown[]): Record<string, unknown> | undefined;
}

interface NodeSqliteDatabase {
  exec(sql: string): void;
  prepare(sql: string): NodeSqliteStatement;
  close(): void;
}

interface NodeSqliteModule {
  DatabaseSync: new (path: string) => NodeSqliteDatabase;
}

declare const require: (id: string) => unknown;

function load_node_sqlite(): NodeSqliteModule {
  try {
    return require('node:sqlite') as NodeSqliteModule;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`node:sqlite is unavailable (Node 22.5+ required): ${message}`);
  }
}

// Statements that produce a result set. The app's SQL never uses RETURNING, so classifying by
// the leading keyword is sufficient and keeps the adapter dependency free.
function produces_rows(sql: string): boolean {
  return /^(select|pragma|with|explain|values)\b/i.test(sql);
}

function to_sql_value(value: unknown): SqlValue {
  if (value === null || typeof value === 'string' || typeof value === 'number' || typeof value === 'bigint') {
    return value;
  }
  if (value instanceof Uint8Array) {
    return value;
  }
  throw new Error(`Unsupported node:sqlite value: ${typeof value}`);
}

function to_sql_row(row: Record<string, unknown>): SqlRow {
  const result: SqlRow = {};
  for (const [key, value] of Object.entries(row)) {
    result[key] = to_sql_value(value);
  }
  return result;
}

class NodePreparedStatement implements PreparedStatement {
  private readonly statement: NodeSqliteStatement;

  constructor(statement: NodeSqliteStatement) {
    this.statement = statement;
  }

  // node:sqlite statements are synchronous, so run/get/all resolve immediately.
  async run(params?: SqlParams): Promise<ResultSet> {
    const info = this.statement.run(...(params ?? []));
    return {
      columns: [],
      rows: [],
      rowsAffected: Number(info.changes),
      lastInsertRowid: Number(info.lastInsertRowid),
    };
  }

  async get(params?: SqlParams): Promise<SqlRow | null> {
    const row = this.statement.get(...(params ?? []));
    return row === undefined ? null : to_sql_row(row);
  }

  async all(params?: SqlParams): Promise<SqlRow[]> {
    return this.statement.all(...(params ?? [])).map(to_sql_row);
  }
}

export class NodeSqliteExecutor implements SqlExecutor {
  private readonly database: NodeSqliteDatabase;
  private readonly statements = new Map<string, PreparedStatement>();
  private closed = false;

  constructor(database: NodeSqliteDatabase) {
    this.database = database;
  }

  static open(path = ':memory:'): NodeSqliteExecutor {
    const sqlite = load_node_sqlite();
    const database = new sqlite.DatabaseSync(path);
    // Pragmas run via exec so multi assignment and journal mode queries work on any Node version.
    for (const sql of OPEN_PRAGMAS) {
      database.exec(sql);
    }
    return new NodeSqliteExecutor(database);
  }

  async execute(sql: string, params?: SqlParams): Promise<ResultSet> {
    this.assert_open();
    const statement = this.prepare_native(sql);
    if (produces_rows(sql)) {
      const rows = statement.all(...(params ?? [])).map(to_sql_row);
      return {
        columns: rows[0] ? Object.keys(rows[0]) : [],
        rows,
        rowsAffected: 0,
        lastInsertRowid: null,
      };
    }
    const info = statement.run(...(params ?? []));
    return {
      columns: [],
      rows: [],
      rowsAffected: Number(info.changes),
      lastInsertRowid: Number(info.lastInsertRowid),
    };
  }

  async executeBatch(statements: readonly SqlStatement[]): Promise<void> {
    await with_transaction(this, async () => {
      for (const statement of statements) {
        await this.execute(statement.sql, statement.params);
      }
    });
  }

  transaction<T>(fn: (tx: SqlExecutor) => Promise<T>): Promise<T> {
    return with_transaction(this, fn);
  }

  prepare(sql: string): PreparedStatement {
    this.assert_open();
    const cached = this.statements.get(sql);
    if (cached) {
      return cached;
    }
    const prepared = new NodePreparedStatement(this.prepare_native(sql));
    this.statements.set(sql, prepared);
    return prepared;
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.statements.clear();
    this.database.close();
  }

  private prepare_native(sql: string): NodeSqliteStatement {
    return this.database.prepare(sql);
  }

  private assert_open(): void {
    if (this.closed) {
      throw new Error('NodeSqliteExecutor used after close');
    }
  }
}
