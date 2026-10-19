// Outcome rules for logging attempts (flash, send, project, fail).
// The repository computes the next attempt number and the climb's hold ids, then this module
// validates the outcome against them (US-12).

import { DomainValidationError } from '../errors';
import { is_attempt_outcome, type AttemptOutcome } from '../models/attempt';

export interface AttemptInput {
  outcome: AttemptOutcome;
  fellOnHoldId: string | null;
  notes?: string | null;
  videoId?: string | null;
}

export interface AttemptRuleContext {
  // The attempt number the repository will assign (next per session and climb).
  attemptNo: number;
  // Hold ids that belong to the attempt's climb.
  climbHoldIds: readonly string[];
}

export interface AttemptValidation {
  // Normalized fall hold. flash and send record null by rule; a provided value yields a warning
  // instead of silently disappearing (requirements edge case: outcome contradiction).
  fellOnHoldId: string | null;
  warnings: readonly string[];
}

export function validate_attempt(input: AttemptInput, context: AttemptRuleContext): AttemptValidation {
  if (!is_attempt_outcome(input.outcome)) {
    throw new DomainValidationError('invalid_outcome', `Unknown attempt outcome: ${String(input.outcome)}`);
  }
  if (!Number.isInteger(context.attemptNo) || context.attemptNo < 1) {
    throw new DomainValidationError('invalid_attempt_no', 'Attempt number must be a positive integer.');
  }
  if (input.outcome === 'flash' && context.attemptNo !== 1) {
    throw new DomainValidationError(
      'flash_requires_first_attempt',
      'A flash means the climb was sent on the first attempt of this session. Record later sends as send.',
    );
  }

  if (input.fellOnHoldId !== null && !context.climbHoldIds.includes(input.fellOnHoldId)) {
    throw new DomainValidationError(
      'fall_hold_not_on_climb',
      'The selected fall hold does not belong to this climb.',
    );
  }

  const warnings: string[] = [];
  let fellOnHoldId = input.fellOnHoldId;
  if ((input.outcome === 'flash' || input.outcome === 'send') && fellOnHoldId !== null) {
    warnings.push('outcome_records_no_fall_hold');
    fellOnHoldId = null;
  }
  return { fellOnHoldId, warnings };
}
