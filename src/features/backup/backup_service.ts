// Automatic rotating backups and restore (US-15, US-16). A backup is a .cybersend zip written to
// the document backups directory; the newest 10 are kept. Automatic triggers: session close (always)
// and app background (at most hourly, throttled through the settings table).
//
// Atomicity note: restore applies the imported payload through import_payload_json, which is one
// transaction over every table, plus a best effort file snapshot of the main database taken
// before the import. This satisfies "restore replaces data atomically" without a physical file
// swap, which cannot be verified on this machine (no Xcode available).

import { File } from 'expo-file-system';

import type { SqlExecutor } from '../../data/db/executor';
import type { Repositories } from '../../data/repositories';
import { SETTINGS_KEY_LAST_BACKUP_AT } from '../../domain/models/settings';
import { now_iso } from '../../data/time';
import { backups_directory, build_backup_bytes, type BuildBackupOptions } from './export_service';
import { import_payload_json, type ImportReport } from './import_service';
import { BACKUP_EXTENSION, unpack_backup } from './zip';

export const MAX_BACKUPS_KEPT = 10;
export const AUTOMATIC_BACKUP_INTERVAL_MS = 60 * 60 * 1000;

export type BackupTrigger = 'session_close' | 'app_background';

export interface BackupFile {
  name: string;
  uri: string;
}

export interface RestoreResult extends ImportReport {
  warnings: readonly string[];
}

// Pure rotation helper: backup names embed an ISO timestamp, so lexicographic order is
// chronological. Returns the names to delete, keeping the newest `keep`.
export function backups_to_delete(names: readonly string[], keep = MAX_BACKUPS_KEPT): string[] {
  const sorted = [...names].sort().reverse();
  return sorted.slice(keep);
}

function timestamp_slug(): string {
  return now_iso().replace(/[:.]/g, '-');
}

export async function list_backups(): Promise<BackupFile[]> {
  const entries = backups_directory().list();
  return entries
    .filter((entry): entry is File => entry instanceof File && entry.name.endsWith(BACKUP_EXTENSION))
    .map((entry) => ({ name: entry.name, uri: entry.uri }));
}

async function rotate_backups(): Promise<void> {
  const backups = await list_backups();
  for (const name of backups_to_delete(backups.map((backup) => backup.name))) {
    const file = new File(backups_directory(), name);
    if (file.exists) {
      file.delete();
    }
  }
}

export async function write_backup(repos: Repositories, options: BuildBackupOptions = {}): Promise<string> {
  const bytes = await build_backup_bytes(repos, options);
  const file = new File(backups_directory(), `backup_${timestamp_slug()}${BACKUP_EXTENSION}`);
  await file.write(bytes);
  await rotate_backups();
  await repos.settings.set(SETTINGS_KEY_LAST_BACKUP_AT, JSON.stringify(now_iso()));
  return file.uri;
}

// Returns true when a backup was written, false when a background trigger was throttled.
// Failures propagate so the UI can show the persistent warning badge (storage full edge case).
export async function maybe_write_automatic_backup(repos: Repositories, trigger: BackupTrigger): Promise<boolean> {
  if (trigger === 'app_background') {
    const last = await repos.settings.getJson<string>(SETTINGS_KEY_LAST_BACKUP_AT);
    if (last !== null) {
      const last_ms = Date.parse(last);
      if (Number.isFinite(last_ms) && Date.now() - last_ms < AUTOMATIC_BACKUP_INTERVAL_MS) {
        return false;
      }
    }
  }
  await write_backup(repos);
  return true;
}

export interface RestoreDeps {
  executor: SqlExecutor;
  repos: Repositories;
}

export interface RestoreOptions {
  // Absolute path of the main database file. When provided, a pre-import snapshot copy is taken
  // into the backups directory; snapshot failures are reported as warnings and never block a
  // restore, because the import itself is a single transaction.
  databasePath?: string;
}

export async function restore_backup(
  deps: RestoreDeps,
  source: { bytes(): Promise<Uint8Array> },
  options: RestoreOptions = {},
): Promise<RestoreResult> {
  const warnings: string[] = [];

  if (options.databasePath !== undefined) {
    try {
      const database_file = new File(options.databasePath);
      if (database_file.exists) {
        const snapshot = new File(backups_directory(), `pre_import_${timestamp_slug()}.sqlite`);
        await database_file.copy(snapshot);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      warnings.push(`Pre-import snapshot failed: ${message}`);
    }
  }

  const archive = unpack_backup(await source.bytes());
  const report = await import_payload_json(archive.data, { executor: deps.executor, dump: deps.repos.dump });
  return { ...report, warnings };
}
