// CSV export (RFC 4180) for sessions, attempts, and climbs (US-14.2). Export only; full fidelity
// import is JSON (requirements section 7).

import type { Attempt } from '../../domain/models/attempt';
import type { Climb } from '../../domain/models/climb';
import type { Session } from '../../domain/models/session';

const CRLF = '\r\n';

export function csv_escape(field: string | number | null): string {
  if (field === null) {
    return '';
  }
  const text = String(field);
  if (/[",\r\n]/.test(text)) {
    return `"${text.replace(/"/g, '""')}"`;
  }
  return text;
}

export function to_csv(headers: readonly string[], rows: readonly (readonly (string | number | null)[])[]): string {
  const lines = [
    headers.map(csv_escape).join(','),
    ...rows.map((row) => row.map(csv_escape).join(',')),
  ];
  return lines.join(CRLF) + CRLF;
}

export const SESSION_CSV_HEADERS: readonly string[] = [
  'id',
  'gym_id',
  'started_at',
  'ended_at',
  'rpe',
  'notes',
  'created_at',
  'updated_at',
];

export function sessions_to_csv(sessions: readonly Session[]): string {
  return to_csv(
    SESSION_CSV_HEADERS,
    sessions.map((session) => [
      session.id,
      session.gymId,
      session.startedAt,
      session.endedAt,
      session.rpe,
      session.notes,
      session.createdAt,
      session.updatedAt,
    ]),
  );
}

export const ATTEMPT_CSV_HEADERS: readonly string[] = [
  'id',
  'session_id',
  'climb_id',
  'attempt_no',
  'outcome',
  'fell_on_hold_id',
  'notes',
  'created_at',
];

export function attempts_to_csv(attempts: readonly Attempt[]): string {
  return to_csv(
    ATTEMPT_CSV_HEADERS,
    attempts.map((attempt) => [
      attempt.id,
      attempt.sessionId,
      attempt.climbId,
      attempt.attemptNo,
      attempt.outcome,
      attempt.fellOnHoldId,
      attempt.notes,
      attempt.createdAt,
    ]),
  );
}

export const CLIMB_CSV_HEADERS: readonly string[] = [
  'id',
  'gym_id',
  'wall_id',
  'name',
  'grade_system',
  'grade_level_id',
  'color_circuit',
  'angle_deg',
  'is_active',
  'is_archived',
  'created_at',
  'updated_at',
];

export function climbs_to_csv(climbs: readonly Climb[]): string {
  return to_csv(
    CLIMB_CSV_HEADERS,
    climbs.map((climb) => [
      climb.id,
      climb.gymId,
      climb.wallId,
      climb.name,
      climb.gradeSystem,
      climb.gradeRaw,
      climb.colorCircuit,
      climb.angleDeg,
      climb.isActive ? 1 : 0,
      climb.isArchived ? 1 : 0,
      climb.createdAt,
      climb.updatedAt,
    ]),
  );
}
