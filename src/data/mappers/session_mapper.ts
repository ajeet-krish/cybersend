import type { Session, SessionSummary } from '../../domain/models/session';
import type { SqlRow, SqlValue } from '../db/executor';
import { row_int, row_opt_int, row_opt_text, row_text } from './common';

export function row_to_session(row: SqlRow): Session {
  return {
    id: row_text(row, 'id'),
    gymId: row_text(row, 'gym_id'),
    startedAt: row_text(row, 'started_at'),
    endedAt: row_opt_text(row, 'ended_at'),
    rpe: row_opt_int(row, 'rpe'),
    notes: row_opt_text(row, 'notes'),
    createdAt: row_text(row, 'created_at'),
    updatedAt: row_text(row, 'updated_at'),
  };
}

export function session_to_row(session: Session): Record<string, SqlValue> {
  return {
    id: session.id,
    gym_id: session.gymId,
    started_at: session.startedAt,
    ended_at: session.endedAt,
    rpe: session.rpe,
    notes: session.notes,
    created_at: session.createdAt,
    updated_at: session.updatedAt,
  };
}

// The history query aliases the attempt count as attempt_count.
export function row_to_session_summary(row: SqlRow): SessionSummary {
  return {
    ...row_to_session(row),
    attemptCount: row_int(row, 'attempt_count'),
  };
}
