// Timestamps are ISO 8601 UTC text per docs/schema.sql conventions.

export function now_iso(): string {
  return new Date().toISOString();
}
