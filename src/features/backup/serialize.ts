// Pure export payload construction and JSON serialization. US-14: JSON contains all entities
// plus schema_version and round-trips losslessly.

import type { TableDump } from '../../data/repositories/dump_repository';
import { TABLES_IN_INSERT_ORDER } from '../../domain/validation/tables';

export const EXPORT_APP_ID = 'cybersend';

export interface ExportPayload {
  app: typeof EXPORT_APP_ID;
  schema_version: number;
  exported_at: string;
  tables: TableDump;
}

// Every table is present in the payload, even when empty, so import validation is uniform.
export function build_export_payload(dump: TableDump, schemaVersion: number, exportedAt: string): ExportPayload {
  const tables = {} as TableDump;
  for (const name of TABLES_IN_INSERT_ORDER) {
    tables[name] = dump[name] ?? [];
  }
  return {
    app: EXPORT_APP_ID,
    schema_version: schemaVersion,
    exported_at: exportedAt,
    tables,
  };
}

export function serialize_export_payload(payload: ExportPayload): string {
  return JSON.stringify(payload, null, 2);
}
