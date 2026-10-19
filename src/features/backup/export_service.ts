// Device side export: JSON and CSV files written under the cache exports directory and shared
// through the iOS share sheet (US-14.3). Works fully offline.

import Constants from 'expo-constants';
import * as Crypto from 'expo-crypto';
import { Directory, File, Paths } from 'expo-file-system';
import * as Sharing from 'expo-sharing';

import type { Attempt } from '../../domain/models/attempt';
import { now_iso } from '../../data/time';
import type { Repositories } from '../../data/repositories';
import { attempts_to_csv, climbs_to_csv, sessions_to_csv } from './csv';
import { build_export_payload, serialize_export_payload } from './serialize';
import type { BackupManifest } from './zip';
import { pack_backup } from './zip';

export type CsvEntity = 'sessions' | 'attempts' | 'climbs';

export function app_version(): string {
  return Constants.expoConfig?.version ?? '0.0.0';
}

function timestamp_slug(iso: string): string {
  return iso.replace(/[:.]/g, '-');
}

function ensure_directory(name: string): Directory {
  const directory = new Directory(Paths.cache, name);
  if (!directory.exists) {
    directory.create({ idempotent: true });
  }
  return directory;
}

export function backups_directory(): Directory {
  const directory = new Directory(Paths.document, 'backups');
  if (!directory.exists) {
    directory.create({ idempotent: true });
  }
  return directory;
}

export async function build_export_json(repos: Repositories): Promise<string> {
  const [dump, schemaVersion] = await Promise.all([repos.dump.dumpAll(), repos.dump.schemaVersion()]);
  return serialize_export_payload(build_export_payload(dump, schemaVersion, now_iso()));
}

export async function write_export_json(json: string): Promise<string> {
  const file = new File(ensure_directory('exports'), `cybersend_export_${timestamp_slug(now_iso())}.json`);
  await file.write(json);
  return file.uri;
}

export async function build_export_csv(repos: Repositories, entity: CsvEntity): Promise<string> {
  if (entity === 'sessions') {
    return sessions_to_csv(await repos.sessions.list(100000));
  }
  if (entity === 'climbs') {
    return climbs_to_csv(await repos.climbs.list({ includeArchived: true, includeInactive: true }));
  }
  const sessions = await repos.sessions.list(100000);
  const attempts: Attempt[] = [];
  for (const session of sessions) {
    attempts.push(...(await repos.attempts.listBySession(session.id)));
  }
  return attempts_to_csv(attempts);
}

export async function write_export_csv(csv: string, entity: CsvEntity): Promise<string> {
  const file = new File(ensure_directory('exports'), `cybersend_${entity}_${timestamp_slug(now_iso())}.csv`);
  await file.write(csv);
  return file.uri;
}

export async function share_file(uri: string): Promise<void> {
  if (!(await Sharing.isAvailableAsync())) {
    throw new Error('The share sheet is not available on this device.');
  }
  await Sharing.shareAsync(uri);
}

// Reads a media file stored relative to the document root. Returns null when the file is gone
// (for example, a retention sweep already deleted a video).
async function read_media_bytes(relative_uri: string): Promise<Uint8Array | null> {
  const file = new File(Paths.document, relative_uri);
  if (!file.exists) {
    return null;
  }
  return file.bytes();
}

async function sha256(bytes: Uint8Array): Promise<string> {
  // Copy into a fresh buffer so the digest receives an ArrayBuffer backed view (TS 5.7 typed
  // arrays are generic over the backing buffer type).
  const digest = await Crypto.digest(Crypto.CryptoDigestAlgorithm.SHA256, new Uint8Array(bytes));
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

export interface BuildBackupOptions {
  includeVideos?: boolean;
}

// Full backup: manifest.json plus data.json plus media (photos always; videos only when kept or
// opted in), zipped into one .cybersend file (docs/architecture.md backup and export).
export async function build_backup_bytes(repos: Repositories, options: BuildBackupOptions = {}): Promise<Uint8Array> {
  const [dump, schemaVersion] = await Promise.all([repos.dump.dumpAll(), repos.dump.schemaVersion()]);
  const payload = build_export_payload(dump, schemaVersion, now_iso());

  const media: Record<string, Uint8Array> = {};
  const media_entries: { path: string; sha256: string }[] = [];
  for (const photo of dump.photos) {
    const uri = typeof photo.uri === 'string' ? photo.uri : null;
    if (uri === null) {
      continue;
    }
    const bytes = await read_media_bytes(uri);
    if (bytes === null) {
      continue;
    }
    media[uri] = bytes;
    media_entries.push({ path: uri, sha256: await sha256(bytes) });
  }
  if (options.includeVideos ?? false) {
    for (const video of dump.videos) {
      const uri = typeof video.uri === 'string' ? video.uri : null;
      const keep = video.retention_class === 'keep';
      if (uri === null || !keep) {
        continue;
      }
      const bytes = await read_media_bytes(uri);
      if (bytes === null) {
        continue;
      }
      media[uri] = bytes;
      media_entries.push({ path: uri, sha256: await sha256(bytes) });
    }
  }

  const manifest: BackupManifest = {
    app: 'cybersend',
    app_version: app_version(),
    schema_version: schemaVersion,
    created_at: now_iso(),
    media: media_entries,
  };
  return pack_backup({ manifest, data: serialize_export_payload(payload), media });
}
