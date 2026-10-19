// .cybersend backup archive: a zip of manifest.json, data.json, and optional media files,
// produced with fflate (docs/decisions.md 2026-10-19, backup as zip). Pure code, unit testable
// in Node.

import { strFromU8, strToU8, unzipSync, zipSync } from 'fflate';

export const BACKUP_EXTENSION = '.cybersend';

export interface BackupManifestMediaEntry {
  path: string;
  sha256: string;
}

export interface BackupManifest {
  app: 'cybersend';
  app_version: string;
  schema_version: number;
  created_at: string;
  media: readonly BackupManifestMediaEntry[];
}

export interface BackupArchive {
  manifest: BackupManifest;
  data: string;
  media: Record<string, Uint8Array>;
}

export class BackupArchiveError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'BackupArchiveError';
  }
}

export function pack_backup(archive: BackupArchive): Uint8Array {
  const files: Record<string, Uint8Array> = {
    'manifest.json': strToU8(JSON.stringify(archive.manifest, null, 2)),
    'data.json': strToU8(archive.data),
  };
  for (const [path, bytes] of Object.entries(archive.media)) {
    files[`media/${path}`] = bytes;
  }
  return zipSync(files, { level: 6 });
}

function is_manifest(raw: unknown): raw is BackupManifest {
  if (typeof raw !== 'object' || raw === null) {
    return false;
  }
  const manifest = raw as Record<string, unknown>;
  return (
    manifest.app === 'cybersend' &&
    typeof manifest.app_version === 'string' &&
    typeof manifest.schema_version === 'number' &&
    typeof manifest.created_at === 'string' &&
    Array.isArray(manifest.media)
  );
}

export function unpack_backup(bytes: Uint8Array): BackupArchive {
  let files: Record<string, Uint8Array>;
  try {
    files = unzipSync(bytes);
  } catch {
    throw new BackupArchiveError('The backup file could not be opened. Nothing was restored.');
  }

  const manifest_bytes = files['manifest.json'];
  const data_bytes = files['data.json'];
  if (manifest_bytes === undefined || data_bytes === undefined) {
    throw new BackupArchiveError('The backup archive is missing manifest.json or data.json. Nothing was restored.');
  }

  let manifest_raw: unknown;
  try {
    manifest_raw = JSON.parse(strFromU8(manifest_bytes));
  } catch {
    throw new BackupArchiveError('The backup manifest is not valid JSON. Nothing was restored.');
  }
  if (!is_manifest(manifest_raw)) {
    throw new BackupArchiveError('The backup manifest is not a CyberSend manifest. Nothing was restored.');
  }

  const media: Record<string, Uint8Array> = {};
  const prefix = 'media/';
  for (const [path, file_bytes] of Object.entries(files)) {
    if (path.startsWith(prefix) && path.length > prefix.length) {
      media[path.slice(prefix.length)] = file_bytes;
    }
  }

  return { manifest: manifest_raw, data: strFromU8(data_bytes), media };
}
