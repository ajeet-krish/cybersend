// Session entity and RPE rules. RPE is session level, integer 1 to 10 (requirements section 2).

import { DomainValidationError } from '../errors';

export interface Session {
  id: string;
  gymId: string;
  startedAt: string;
  endedAt: string | null;
  rpe: number | null;
  notes: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface SessionSummary extends Session {
  attemptCount: number;
}

export const MIN_RPE = 1;
export const MAX_RPE = 10;

export function is_session_open(session: Session): boolean {
  return session.endedAt === null;
}

// Validates session RPE regardless of source (US-11.1, edge case RPE out of range).
export function validate_rpe(rpe: number | null): number | null {
  if (rpe === null) {
    return null;
  }
  if (!Number.isInteger(rpe) || rpe < MIN_RPE || rpe > MAX_RPE) {
    throw new DomainValidationError(
      'rpe_out_of_range',
      `RPE must be an integer from ${MIN_RPE} to ${MAX_RPE} (got ${rpe}).`,
    );
  }
  return rpe;
}
