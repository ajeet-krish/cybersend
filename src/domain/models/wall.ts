// Wall entity, part of the gym aggregate.

export interface Wall {
  id: string;
  gymId: string;
  name: string | null;
  angleDeg: number | null;
  angleLabel: string | null;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
}

export const MIN_ANGLE_DEG = 0;
export const MAX_ANGLE_DEG = 90;

// Shared by walls and climbs; both store a wall angle in degrees, nullable.
export function is_angle_valid(angleDeg: number | null): boolean {
  if (angleDeg === null) {
    return true;
  }
  return Number.isFinite(angleDeg) && angleDeg >= MIN_ANGLE_DEG && angleDeg <= MAX_ANGLE_DEG;
}
