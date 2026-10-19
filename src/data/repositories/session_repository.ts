// Session repository. Rules: at most one open session at a time (US-11.2), closing is idempotent
// (US-11.3), RPE is validated in the domain layer regardless of source (US-11.1).

import { DomainValidationError } from '../../domain/errors';
import type { Session, SessionSummary } from '../../domain/models/session';
import { is_session_open, validate_rpe } from '../../domain/models/session';
import type { SqlExecutor } from '../db/executor';
import { generate_id } from '../id';
import { row_to_session, row_to_session_summary } from '../mappers';
import { now_iso } from '../time';
import { with_transaction } from '../db/transaction';

export interface CreateSessionInput {
  gymId: string;
  startedAt?: string;
  notes?: string | null;
}

export interface CloseSessionInput {
  endedAt?: string;
  rpe?: number | null;
  notes?: string | null;
}

export class SessionRepository {
  private readonly executor: SqlExecutor;

  constructor(executor: SqlExecutor) {
    this.executor = executor;
  }

  async create(input: CreateSessionInput): Promise<Session> {
    const open = await this.getOpen();
    if (open !== null) {
      throw new DomainValidationError(
        'open_session_exists',
        'A session is already open. Close it before starting another one.',
      );
    }
    const gym = await this.executor.prepare('SELECT id FROM gyms WHERE id = ?').get([input.gymId]);
    if (gym === null) {
      throw new DomainValidationError('gym_not_found', 'Gym not found.');
    }
    const timestamp = now_iso();
    const session: Session = {
      id: generate_id(),
      gymId: input.gymId,
      startedAt: input.startedAt ?? timestamp,
      endedAt: null,
      rpe: null,
      notes: input.notes ?? null,
      createdAt: timestamp,
      updatedAt: timestamp,
    };
    await this.executor.execute(
      'INSERT INTO sessions (id, gym_id, started_at, ended_at, rpe, notes, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [session.id, session.gymId, session.startedAt, session.endedAt, session.rpe, session.notes, session.createdAt, session.updatedAt],
    );
    return session;
  }

  async getOpen(): Promise<Session | null> {
    const row = await this.executor
      .prepare('SELECT * FROM sessions WHERE ended_at IS NULL ORDER BY started_at DESC LIMIT 1')
      .get();
    return row === null ? null : row_to_session(row);
  }

  async get(id: string): Promise<Session | null> {
    const row = await this.executor.prepare('SELECT * FROM sessions WHERE id = ?').get([id]);
    return row === null ? null : row_to_session(row);
  }

  // Idempotent: closing an already closed session returns it unchanged (US-11.3).
  async close(id: string, input: CloseSessionInput = {}): Promise<Session> {
    return with_transaction(this.executor, async (tx) => {
      const existing = await this.require_session(tx, id);
      if (!is_session_open(existing)) {
        return existing;
      }
      const rpe = input.rpe === undefined ? existing.rpe : validate_rpe(input.rpe);
      const session: Session = {
        ...existing,
        endedAt: input.endedAt ?? now_iso(),
        rpe,
        notes: input.notes === undefined ? existing.notes : input.notes,
        updatedAt: now_iso(),
      };
      await tx.execute('UPDATE sessions SET ended_at = ?, rpe = ?, notes = ?, updated_at = ? WHERE id = ?', [
        session.endedAt,
        session.rpe,
        session.notes,
        session.updatedAt,
        id,
      ]);
      return session;
    });
  }

  // Edits notes and RPE on any session (used by session detail).
  async update(id: string, patch: { rpe?: number | null; notes?: string | null }): Promise<Session> {
    const existing = await this.require_session(this.executor, id);
    const rpe = patch.rpe === undefined ? existing.rpe : validate_rpe(patch.rpe);
    const session: Session = {
      ...existing,
      rpe,
      notes: patch.notes === undefined ? existing.notes : patch.notes,
      updatedAt: now_iso(),
    };
    await this.executor.execute('UPDATE sessions SET rpe = ?, notes = ?, updated_at = ? WHERE id = ?', [
      session.rpe,
      session.notes,
      session.updatedAt,
      id,
    ]);
    return session;
  }

  // Reverse chronological history with attempt counts (US-22.1).
  async list(limit = 200): Promise<SessionSummary[]> {
    const result = await this.executor
      .prepare(
        `SELECT sessions.*, (SELECT COUNT(*) FROM attempts WHERE attempts.session_id = sessions.id) AS attempt_count
         FROM sessions ORDER BY sessions.started_at DESC LIMIT ?`,
      )
      .all([limit]);
    return result.map(row_to_session_summary);
  }

  async delete(id: string): Promise<void> {
    await this.executor.execute('DELETE FROM sessions WHERE id = ?', [id]);
  }

  private async require_session(tx: SqlExecutor, id: string): Promise<Session> {
    const row = await tx.prepare('SELECT * FROM sessions WHERE id = ?').get([id]);
    if (row === null) {
      throw new DomainValidationError('session_not_found', 'Session not found.');
    }
    return row_to_session(row);
  }
}
