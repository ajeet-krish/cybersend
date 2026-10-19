import type { Photo, PhotoSource } from '../../domain/models/photo';
import { PHOTO_SOURCES } from '../../domain/models/photo';
import type { SqlRow, SqlValue } from '../db/executor';
import { row_int, row_opt_text, row_text } from './common';

function parse_source(raw: string): PhotoSource {
  if ((PHOTO_SOURCES as readonly string[]).includes(raw)) {
    return raw as PhotoSource;
  }
  throw new Error(`Unknown photo source in database: ${raw}`);
}

export function row_to_photo(row: SqlRow): Photo {
  return {
    id: row_text(row, 'id'),
    climbId: row_opt_text(row, 'climb_id'),
    sessionId: row_opt_text(row, 'session_id'),
    uri: row_text(row, 'uri'),
    thumbUri: row_opt_text(row, 'thumb_uri'),
    width: row_int(row, 'width'),
    height: row_int(row, 'height'),
    source: parse_source(row_text(row, 'source')),
    capturedAt: row_text(row, 'captured_at'),
    createdAt: row_text(row, 'created_at'),
  };
}

export function photo_to_row(photo: Photo): Record<string, SqlValue> {
  return {
    id: photo.id,
    climb_id: photo.climbId,
    session_id: photo.sessionId,
    uri: photo.uri,
    thumb_uri: photo.thumbUri,
    width: photo.width,
    height: photo.height,
    source: photo.source,
    captured_at: photo.capturedAt,
    created_at: photo.createdAt,
  };
}
