// SQL executor port. Repositories depend only on this interface and the row helpers in
// src/data/mappers. The node:sqlite adapter (Jest, hermetic tests) and the op-sqlite adapter
// (device) are the only implementations. Screens and hooks never import either driver (US-13).

// Values that can be bound to a statement parameter. Matches what SQLite stores:
// NULL, INTEGER, REAL, TEXT, and BLOB.
export type SqlValue = null | number | bigint | string | Uint8Array;

export type SqlParams = readonly SqlValue[];

// A single result row keyed by snake_case column name, exactly as SQLite returned it.
export type SqlRow = Record<string, SqlValue>;

export interface ResultSet {
  columns: readonly string[];
  rows: readonly SqlRow[];
  rowsAffected: number;
  lastInsertRowid: number | null;
}

export type SqlStatement = {
  sql: string;
  params?: SqlParams;
};

export interface PreparedStatement {
  run(params?: SqlParams): Promise<ResultSet>;
  get(params?: SqlParams): Promise<SqlRow | null>;
  all(params?: SqlParams): Promise<SqlRow[]>;
}

export interface SqlExecutor {
  // Executes a single statement with optional bound parameters.
  execute(sql: string, params?: SqlParams): Promise<ResultSet>;
  // Executes statements in order. Atomic: wrapped in a transaction unless one is already open,
  // in which case the batch joins the outer transaction (see src/data/db/transaction.ts).
  executeBatch(statements: readonly SqlStatement[]): Promise<void>;
  // Runs fn inside a transaction. Nested calls on the same executor join the outer transaction,
  // so only the outermost call commits or rolls back.
  transaction<T>(fn: (tx: SqlExecutor) => Promise<T>): Promise<T>;
  // Returns a cached prepared statement for the SQL text. Statements are keyed per connection.
  prepare(sql: string): PreparedStatement;
  close(): Promise<void>;
}
