// Photo entity. Media uris are relative to the app document root for portability (docs/schema.sql
// conventions). Capture and tagging flows arrive in Phase 2.

export type PhotoSource = 'camera' | 'library';

export const PHOTO_SOURCES: readonly PhotoSource[] = ['camera', 'library'];

export interface Photo {
  id: string;
  climbId: string | null;
  sessionId: string | null;
  uri: string;
  thumbUri: string | null;
  width: number;
  height: number;
  source: PhotoSource;
  capturedAt: string;
  createdAt: string;
}
