// Attempt entity and outcome enum. Outcome is a single enum column, never a status flag
// (requirements section 2).

export type AttemptOutcome = 'flash' | 'send' | 'project' | 'fail';

export const ATTEMPT_OUTCOMES: readonly AttemptOutcome[] = ['flash', 'send', 'project', 'fail'];

export function is_attempt_outcome(value: unknown): value is AttemptOutcome {
  return typeof value === 'string' && (ATTEMPT_OUTCOMES as readonly string[]).includes(value);
}

export interface Attempt {
  id: string;
  sessionId: string;
  climbId: string;
  attemptNo: number;
  outcome: AttemptOutcome;
  fellOnHoldId: string | null;
  videoId: string | null;
  notes: string | null;
  // The moment the attempt happened. docs/schema.sql stores this in attempts.created_at.
  createdAt: string;
}
