// Gym entity. Storage column note: docs/schema.sql models gym archival as is_active (0 = archived),
// requirements US-8 calls the same concept is_archived.

export interface Gym {
  id: string;
  name: string;
  timezone: string | null;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
}

export function is_gym_archived(gym: Gym): boolean {
  return !gym.isActive;
}
