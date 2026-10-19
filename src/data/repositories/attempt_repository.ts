// Attempt repository. log_attempt is the canonical multi table transaction: it computes the next
// attempt number per (session_id, climb_id), validates the outcome in the domain layer (flash
// implies first attempt, fall hold must belong to the climb), and inserts one row atomically
// (US-12).

import { validate_attempt } from '../../domain/attempts/rules';
import type { AttemptInput } from '../../domain/attempts/rules';
import { DomainValidationError } from '../../domain/errors';
import type { Attempt } from '../../domain/models/attempt';
import type { SqlExecutor, SqlRow } from '../db/executor';
import { with_transaction } from '../db/transaction';
import { generate_id } from '../id';
import { attempt_to_row, row_to_attempt } from '../mappers';
import { row_int, row_text } from '../mappers/common';
import { now_iso } from '../time';

export interface LogAttemptInput extends AttemptInput {
  sessionId: string;
  climbId: string;
  createdAt?: string;
}

export interface LogAttemptResult {
  attempt: Attempt;
  warnings: readonly string[];
}

export interface UpdateAttemptInput {
  outcome?: AttemptInput['outcome'];
  fellOnHoldId?: string | null;
  notes?: string | null;
}

const INSERT_ATTEMPT_SQL = `INSERT INTO attempts (id, session_id, climb_id, attempt_no, outcome, fell_on_hold_id,
  video_id, notes, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`;

export class AttemptRepository {
  private readonly executor: SqlExecutor;

  constructor(executor: SqlExecutor) {
    this.executor = executor;
  }

  async logAttempt(input: LogAttemptInput): Promise<LogAttemptResult> {
    return with_transaction(this.executor, async (tx) => {
      await this.assert_session_exists(tx, input.sessionId);
      await this.assert_climb_exists(tx, input.climbId);
      const attemptNo = await this.nextAttemptNo(tx, input.sessionId, input.climbId);
      const climbHoldIds = await this.climb_hold_ids(tx, input.climbId);
      const validation = validate_attempt(
        {
          outcome: input.outcome,
          fellOnHoldId: input.fellOnHoldId ?? null,
          notes: input.notes ?? null,
          videoId: input.videoId ?? null,
        },
        { attemptNo, climbHoldIds },
      );
      const attempt: Attempt = {
        id: generate_id(),
        sessionId: input.sessionId,
        climbId: input.climbId,
        attemptNo,
        outcome: input.outcome,
        fellOnHoldId: validation.fellOnHoldId,
        videoId: input.videoId ?? null,
        notes: input.notes ?? null,
        createdAt: input.createdAt ?? now_iso(),
      };
      const row = attempt_to_row(attempt);
      // attempt_to_row emits columns in the same order as INSERT_ATTEMPT_SQL.
      await tx.prepare(INSERT_ATTEMPT_SQL).run(Object.values(row));
      return { attempt, warnings: validation.warnings };
    });
  }

  // Re-validates outcome and fall hold against the climb, same rules as log_attempt.
  async updateAttempt(id: string, patch: UpdateAttemptInput): Promise<Attempt> {
    return with_transaction(this.executor, async (tx) => {
      const existing = await this.require_attempt(tx, id);
      const outcome = patch.outcome ?? existing.outcome;
      const fellOnHoldId = patch.fellOnHoldId === undefined ? existing.fellOnHoldId : patch.fellOnHoldId;
      const notes = patch.notes === undefined ? existing.notes : patch.notes;
      const climbHoldIds = await this.climb_hold_ids(tx, existing.climbId);
      const validation = validate_attempt(
        { outcome, fellOnHoldId, notes, videoId: existing.videoId },
        { attemptNo: existing.attemptNo, climbHoldIds },
      );
      await tx.execute('UPDATE attempts SET outcome = ?, fell_on_hold_id = ?, notes = ? WHERE id = ?', [
        outcome,
        validation.fellOnHoldId,
        notes,
        id,
      ]);
      return { ...existing, outcome, fellOnHoldId: validation.fellOnHoldId, notes };
    });
  }

  async get(id: string): Promise<Attempt | null> {
    const row = await this.executor.prepare('SELECT * FROM attempts WHERE id = ?').get([id]);
    return row === null ? null : row_to_attempt(row);
  }

  async listBySession(sessionId: string): Promise<Attempt[]> {
    const result = await this.executor
      .prepare('SELECT * FROM attempts WHERE session_id = ? ORDER BY created_at, attempt_no')
      .all([sessionId]);
    return result.map(row_to_attempt);
  }

  async listByClimb(climbId: string): Promise<Attempt[]> {
    const result = await this.executor
      .prepare('SELECT * FROM attempts WHERE climb_id = ? ORDER BY created_at, attempt_no')
      .all([climbId]);
    return result.map(row_to_attempt);
  }

  async countByClimb(climbId: string): Promise<number> {
    const row = await this.executor.prepare('SELECT COUNT(*) AS n FROM attempts WHERE climb_id = ?').get([climbId]);
    return row === null ? 0 : row_int(row, 'n');
  }

  async delete(id: string): Promise<void> {
    await this.executor.execute('DELETE FROM attempts WHERE id = ?', [id]);
  }

  private async nextAttemptNo(tx: SqlExecutor, sessionId: string, climbId: string): Promise<number> {
    const row = await tx
      .prepare('SELECT COALESCE(MAX(attempt_no), 0) + 1 AS next_no FROM attempts WHERE session_id = ? AND climb_id = ?')
      .get([sessionId, climbId]);
    return row === null ? 1 : row_int(row, 'next_no');
  }

  private async climb_hold_ids(tx: SqlExecutor, climbId: string): Promise<string[]> {
    const result = await tx.prepare('SELECT id FROM holds WHERE climb_id = ?').all([climbId]);
    return result.map((row: SqlRow) => row_text(row, 'id'));
  }

  private async require_attempt(tx: SqlExecutor, id: string): Promise<Attempt> {
    const row = await tx.prepare('SELECT * FROM attempts WHERE id = ?').get([id]);
    if (row === null) {
      throw new DomainValidationError('attempt_not_found', 'Attempt not found.');
    }
    return row_to_attempt(row);
  }

  private async assert_session_exists(tx: SqlExecutor, sessionId: string): Promise<void> {
    const row = await tx.prepare('SELECT id FROM sessions WHERE id = ?').get([sessionId]);
    if (row === null) {
      throw new DomainValidationError('session_not_found', 'Session not found.');
    }
  }

  private async assert_climb_exists(tx: SqlExecutor, climbId: string): Promise<void> {
    const row = await tx.prepare('SELECT id FROM climbs WHERE id = ?').get([climbId]);
    if (row === null) {
      throw new DomainValidationError('climb_not_found', 'Climb not found.');
    }
  }
}
