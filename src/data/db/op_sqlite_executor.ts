// op-sqlite adapter for the SqlExecutor port. This is the device driver (docs/decisions.md D1,
// package @op-engineering/op-sqlite). The adapter is a thin translation of the port onto the
// op-sqlite DB type. The native module is loaded lazily in src/data/db/connection.ts so the app
// degrades gracefully in environments without the native module (for example Expo Go).

import type {
  DB,
  PreparedStatement as OpPreparedStatement,
  QueryResult,
  Scalar,
} from '@op-engineering/op-sqlite';
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

function to_op_scalar(value: SqlValue): Scalar {
  if (value === null || typeof value === 'number' || typeof value === 'string' || value instanceof Uint8Array) {
    return value;
  }
  if (typeof value === 'bigint') {
    if (value >= BigInt(Number.MIN_SAFE_INTEGER) && value <= BigInt(Number.MAX_SAFE_INTEGER)) {
      return Number(value);
    }
    throw new Error('BigInt value out of safe integer range for op-sqlite');
  }
  throw new Error(`Unsupported op-sqlite parameter value: ${typeof value}`);
}

function to_sql_value(value: Scalar): SqlValue {
  if (value === null || typeof value === 'number' || typeof value === 'string') {
    return value;
  }
  if (typeof value === 'boolean') {
    return value ? 1 : 0;
  }
  if (value instanceof Uint8Array) {
    return value;
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  throw new Error('Unsupported op-sqlite result value');
}

function to_sql_row(row: Record<string, Scalar>): SqlRow {
  const result: SqlRow = {};
  for (const [key, value] of Object.entries(row)) {
    result[key] = to_sql_value(value);
  }
  return result;
}

function to_result_set(result: QueryResult): ResultSet {
  const rows = result.rows.map(to_sql_row);
  return {
    columns: result.columnNames ?? (rows[0] ? Object.keys(rows[0]) : []),
    rows,
    rowsAffected: result.rowsAffected,
    lastInsertRowid: result.insertId ?? null,
  };
}

// Serializes bind and execute on one prepared statement so concurrent callers cannot interleave
// bindings on the shared native statement.
class OpPreparedStatementWrapper implements PreparedStatement {
  private readonly statement: OpPreparedStatement;
  private queue: Promise<unknown> = Promise.resolve();

  constructor(statement: OpPreparedStatement) {
    this.statement = statement;
  }

  run(params?: SqlParams): Promise<ResultSet> {
    return this.enqueue(async () => {
      await this.statement.bind((params ?? []).map(to_op_scalar));
      return to_result_set(await this.statement.execute());
    });
  }

  async get(params?: SqlParams): Promise<SqlRow | null> {
    const result = await this.run(params);
    return result.rows[0] ?? null;
  }

  async all(params?: SqlParams): Promise<SqlRow[]> {
    const result = await this.run(params);
    return [...result.rows];
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const next = this.queue.then(operation, operation);
    this.queue = next.then(
      () => undefined,
      () => undefined,
    );
    return next;
  }
}

export class OpSqliteExecutor implements SqlExecutor {
  private readonly db: DB;
  private readonly statements = new Map<string, PreparedStatement>();
  private closed = false;

  constructor(db: DB) {
    this.db = db;
  }

  async execute(sql: string, params?: SqlParams): Promise<ResultSet> {
    this.assert_open();
    const bound = params === undefined ? undefined : params.map(to_op_scalar);
    return to_result_set(await this.db.execute(sql, bound));
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
    const prepared = new OpPreparedStatementWrapper(this.db.prepareStatement(sql));
    this.statements.set(sql, prepared);
    return prepared;
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.statements.clear();
    await this.db.closeAsync();
  }

  // Absolute path of the database file on disk. Used by backup restore to snapshot the main DB
  // file before an import; not part of the SqlExecutor port because it is device specific.
  dbPath(): string {
    return this.db.getDbPath();
  }

  private assert_open(): void {
    if (this.closed) {
      throw new Error('OpSqliteExecutor used after close');
    }
  }
}
