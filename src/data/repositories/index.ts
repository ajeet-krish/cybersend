// Repository barrel plus the factory that wires one repository set per connection.

import type { SqlExecutor } from '../db/executor';
import { AttemptRepository } from './attempt_repository';
import { ClimbRepository } from './climb_repository';
import { DumpRepository } from './dump_repository';
import { GradeRepository } from './grade_repository';
import { GymRepository } from './gym_repository';
import { HoldRepository } from './hold_repository';
import { MediaRepository } from './media_repository';
import { SessionRepository } from './session_repository';
import { SettingsRepository } from './settings_repository';

export * from './attempt_repository';
export * from './climb_repository';
export * from './dump_repository';
export * from './grade_repository';
export * from './gym_repository';
export * from './hold_repository';
export * from './media_repository';
export * from './session_repository';
export * from './settings_repository';

export interface Repositories {
  attempts: AttemptRepository;
  climbs: ClimbRepository;
  dump: DumpRepository;
  grades: GradeRepository;
  gyms: GymRepository;
  holds: HoldRepository;
  media: MediaRepository;
  sessions: SessionRepository;
  settings: SettingsRepository;
}

export function create_repositories(executor: SqlExecutor): Repositories {
  const grades = new GradeRepository(executor);
  return {
    attempts: new AttemptRepository(executor),
    climbs: new ClimbRepository(executor, grades),
    dump: new DumpRepository(executor),
    grades,
    gyms: new GymRepository(executor),
    holds: new HoldRepository(executor),
    media: new MediaRepository(executor),
    sessions: new SessionRepository(executor),
    settings: new SettingsRepository(executor),
  };
}
