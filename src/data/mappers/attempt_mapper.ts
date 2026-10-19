import type { Attempt } from '../../domain/models/attempt';
import { is_attempt_outcome } from '../../domain/models/attempt';
import type { SqlRow, SqlValue } from '../db/executor';
import { row_int, row_opt_text, row_text } from './common';

export function row_to_attempt(row: SqlRow): Attempt {
  const outcome = row_text(row, 'outcome');
  if (!is_attempt_outcome(outcome)) {
    throw new Error(`Unknown attempt outcome in database: ${outcome}`);
  }
  return {
    id: row_text(row, 'id'),
    sessionId: row_text(row, 'session_id'),
    climbId: row_text(row, 'climb_id'),
    attemptNo: row_int(row, 'attempt_no'),
    outcome,
    fellOnHoldId: row_opt_text(row, 'fell_on_hold_id'),
    videoId: row_opt_text(row, 'video_id'),
    notes: row_opt_text(row, 'notes'),
    createdAt: row_text(row, 'created_at'),
  };
}

export function attempt_to_row(attempt: Attempt): Record<string, SqlValue> {
  return {
    id: attempt.id,
    session_id: attempt.sessionId,
    climb_id: attempt.climbId,
    attempt_no: attempt.attemptNo,
    outcome: attempt.outcome,
    fell_on_hold_id: attempt.fellOnHoldId,
    video_id: attempt.videoId,
    notes: attempt.notes,
    created_at: attempt.createdAt,
  };
}
