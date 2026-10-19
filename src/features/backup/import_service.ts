// Import service (US-16). Order of operations guarantees zero writes on any failure:
// 1. parse JSON, 2. validate every row with zod, 3. reject newer schema versions, 4. migrate
// older payload versions forward, 5. only then open one transaction that upserts every table and
// runs foreign_key_check before commit. Re-import is idempotent: upserts key on stable ids.

import type { SqlExecutor } from '../../data/db/executor';
import { CURRENT_SCHEMA_VERSION } from '../../data/db/migrations';
import { with_transaction } from '../../data/db/transaction';
import type { DumpRepository, UpsertReport } from '../../data/repositories/dump_repository';
import { export_payload_schema, type ExportPayloadParsed } from '../../domain/validation/tables';

export class ImportVersionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ImportVersionError';
  }
}

export class ImportPayloadError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ImportPayloadError';
  }
}

export interface PayloadMigration {
  from: number;
  migrate: (payload: ExportPayloadParsed) => ExportPayloadParsed;
}

// docs/schema.sql version 1 is the first shipped schema, so there is nothing to upgrade from in
// production. The registry exists (and is tested via injection) so future schema versions add a
// migration here and old exports keep importing (US-16.2).
export const PAYLOAD_MIGRATIONS: readonly PayloadMigration[] = [];

export interface ImportOptions {
  currentVersion?: number;
  payloadMigrations?: readonly PayloadMigration[];
}

export interface ImportReport {
  schemaVersion: number;
  migratedFrom: number | null;
  upserts: UpsertReport;
}

export function migrate_payload(
  payload: ExportPayloadParsed,
  migrations: readonly PayloadMigration[],
  targetVersion: number,
): ExportPayloadParsed {
  let current = payload;
  let version = payload.schema_version;
  const visited = new Set<number>();
  while (version < targetVersion) {
    const step = migrations.find((migration) => migration.from === version);
    if (step === undefined || visited.has(version)) {
      throw new ImportPayloadError(
        `This file uses schema version ${payload.schema_version}, which this app cannot upgrade to version ${targetVersion}. Nothing was imported.`,
      );
    }
    visited.add(version);
    current = step.migrate(current);
    version += 1;
  }
  return { ...current, schema_version: targetVersion };
}

export async function import_payload_json(
  json: string,
  deps: { executor: SqlExecutor; dump: DumpRepository },
  options: ImportOptions = {},
): Promise<ImportReport> {
  const currentVersion = options.currentVersion ?? CURRENT_SCHEMA_VERSION;

  let raw: unknown;
  try {
    raw = JSON.parse(json);
  } catch {
    throw new ImportPayloadError('The file is not valid JSON. Nothing was imported.');
  }

  const parsed = export_payload_schema.safeParse(raw);
  if (!parsed.success) {
    throw new ImportPayloadError(
      'The file is not a valid CyberSend export (missing entity, bad value, or bad column). Nothing was imported.',
    );
  }

  if (parsed.data.schema_version > currentVersion) {
    throw new ImportVersionError(
      `This file was created by a newer version of CyberSend (file schema ${parsed.data.schema_version}, this app runs schema ${currentVersion}). Update the app first. Nothing was imported.`,
    );
  }

  let payload: ExportPayloadParsed = parsed.data;
  const migratedFrom: number | null = parsed.data.schema_version < currentVersion ? parsed.data.schema_version : null;
  if (migratedFrom !== null) {
    payload = migrate_payload(payload, options.payloadMigrations ?? PAYLOAD_MIGRATIONS, currentVersion);
    const revalidated = export_payload_schema.safeParse(payload);
    if (!revalidated.success) {
      throw new ImportPayloadError('The migrated file is not valid. Nothing was imported.');
    }
    payload = revalidated.data;
  }

  // Everything validated. One transaction applies every table so a mid-import failure rolls
  // back completely.
  const upserts = await with_transaction(deps.executor, async (tx) => {
    const report = await deps.dump.upsertAll(payload.tables, tx);
    const violations = await tx.execute('PRAGMA foreign_key_check');
    if (violations.rows.length > 0) {
      throw new ImportPayloadError('The file contains rows that break foreign key links. Nothing was imported.');
    }
    return report;
  });

  return { schemaVersion: currentVersion, migratedFrom, upserts };
}
