// Hold entity. Coordinates are normalized 0..1 over the source image; radius_norm is relative
// to image width (docs/decisions.md 2026-10-19, normalized coordinates).

import { DomainValidationError } from '../errors';

export type HoldSource = 'manual' | 'detection' | 'board';

export const HOLD_SOURCES: readonly HoldSource[] = ['manual', 'detection', 'board'];

export interface Hold {
  id: string;
  climbId: string;
  xNorm: number;
  yNorm: number;
  radiusNorm: number;
  label: string | null;
  color: string | null;
  source: HoldSource;
  ordinal: number | null;
  createdAt: string;
  updatedAt: string;
}

export function validate_hold_coords(xNorm: number, yNorm: number, radiusNorm: number): void {
  if (!Number.isFinite(xNorm) || xNorm < 0 || xNorm > 1) {
    throw new DomainValidationError('hold_x_out_of_range', 'Hold x coordinate must be within 0 to 1.');
  }
  if (!Number.isFinite(yNorm) || yNorm < 0 || yNorm > 1) {
    throw new DomainValidationError('hold_y_out_of_range', 'Hold y coordinate must be within 0 to 1.');
  }
  if (!Number.isFinite(radiusNorm) || radiusNorm <= 0) {
    throw new DomainValidationError('hold_radius_invalid', 'Hold radius must be greater than 0.');
  }
}
