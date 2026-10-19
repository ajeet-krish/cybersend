// Logbook feature store (zustand): gyms, climbs, the active session, and quick logging. Screens
// read state from here; all writes go through repositories (US-13).

import { create, type StoreApi, type UseBoundStore } from 'zustand';

import type { Repositories } from '../../data/repositories';
import type { Attempt, AttemptOutcome } from '../../domain/models/attempt';
import type { Climb } from '../../domain/models/climb';
import type { GradeSystem } from '../../domain/models/grade';
import type { Gym } from '../../domain/models/gym';
import type { Hold } from '../../domain/models/hold';
import type { Session, SessionSummary } from '../../domain/models/session';

export interface LogAttemptRequest {
  climbId: string;
  outcome: AttemptOutcome;
  fellOnHoldId?: string | null;
}

export interface LogbookState {
  error: string | null;
  gyms: Gym[];
  selectedGymId: string | null;
  quickLogClimbs: Climb[];
  gymClimbs: Climb[];
  activeSession: Session | null;
  activeAttempts: Attempt[];
  holdsByClimb: Record<string, Hold[]>;
  recentSessions: SessionSummary[];
  gradeSystems: GradeSystem[];

  refreshGyms(): Promise<void>;
  selectGym(gymId: string | null): Promise<void>;
  refreshClimbs(): Promise<void>;
  refreshSessions(): Promise<void>;
  startSession(gymId: string): Promise<Session | null>;
  closeActiveSession(input: { rpe?: number | null; notes?: string | null }): Promise<Session | null>;
  logAttempt(request: LogAttemptRequest): Promise<string | null>;
  loadHoldsForClimb(climbId: string): Promise<void>;
}

export type LogbookStore = UseBoundStore<StoreApi<LogbookState>>;

export function createLogbookStore(repos: Repositories): LogbookStore {
  return create<LogbookState>((set, get) => ({
    error: null,
    gyms: [],
    selectedGymId: null,
    quickLogClimbs: [],
    gymClimbs: [],
    activeSession: null,
    activeAttempts: [],
    holdsByClimb: {},
    recentSessions: [],
    gradeSystems: [],

    async refreshGyms() {
      try {
        const [gyms, active_session, grade_systems] = await Promise.all([
          repos.gyms.list(true),
          repos.sessions.getOpen(),
          repos.grades.listSystems(),
        ]);
        const current = get().selectedGymId;
        const selected = current !== null && gyms.some((gym) => gym.id === current)
          ? current
          : (active_session?.gymId ?? gyms.find((gym) => gym.isActive)?.id ?? null);
        set({ gyms, gradeSystems: grade_systems, selectedGymId: selected, activeSession: active_session });
        if (selected !== null) {
          await get().refreshClimbs();
        }
        if (active_session !== null) {
          const attempts = await repos.attempts.listBySession(active_session.id);
          set({ activeAttempts: attempts });
        }
      } catch (error) {
        set({ error: message_of(error) });
      }
    },

    async selectGym(gymId) {
      set({ selectedGymId: gymId });
      await get().refreshClimbs();
    },

    async refreshClimbs() {
      const gym_id = get().selectedGymId;
      if (gym_id === null) {
        set({ quickLogClimbs: [], gymClimbs: [] });
        return;
      }
      try {
        const [quick_log, all] = await Promise.all([
          repos.climbs.list({ gymId: gym_id }),
          repos.climbs.list({ gymId: gym_id, includeArchived: true, includeInactive: true }),
        ]);
        set({ quickLogClimbs: quick_log, gymClimbs: all });
      } catch (error) {
        set({ error: message_of(error) });
      }
    },

    async refreshSessions() {
      try {
        const [recent, active_session] = await Promise.all([repos.sessions.list(500), repos.sessions.getOpen()]);
        set({ recentSessions: recent, activeSession: active_session });
      } catch (error) {
        set({ error: message_of(error) });
      }
    },

    async startSession(gymId) {
      try {
        const session = await repos.sessions.create({ gymId });
        set({ activeSession: session, activeAttempts: [] });
        return session;
      } catch (error) {
        set({ error: message_of(error) });
        return null;
      }
    },

    async closeActiveSession(input) {
      const session = get().activeSession;
      if (session === null) {
        return null;
      }
      try {
        const closed = await repos.sessions.close(session.id, { rpe: input.rpe ?? null, notes: input.notes ?? null });
        set({ activeSession: closed });
        await get().refreshSessions();
        return closed;
      } catch (error) {
        set({ error: message_of(error) });
        return null;
      }
    },

    // Quick log: returns a warning code, an error message, or null on clean success.
    async logAttempt(request) {
      const session = get().activeSession;
      if (session === null) {
        set({ error: 'Start a session before logging attempts.' });
        return 'no_active_session';
      }
      try {
        const { attempt, warnings } = await repos.attempts.logAttempt({
          sessionId: session.id,
          climbId: request.climbId,
          outcome: request.outcome,
          fellOnHoldId: request.fellOnHoldId ?? null,
        });
        set({ activeAttempts: [...get().activeAttempts, attempt] });
        return warnings[0] ?? null;
      } catch (error) {
        set({ error: message_of(error) });
        return message_of(error);
      }
    },

    async loadHoldsForClimb(climbId) {
      if (get().holdsByClimb[climbId] !== undefined) {
        return;
      }
      try {
        const holds = await repos.holds.listByClimb(climbId);
        set({ holdsByClimb: { ...get().holdsByClimb, [climbId]: holds } });
      } catch (error) {
        set({ error: message_of(error) });
      }
    },
  }));
}

function message_of(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
