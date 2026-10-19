// Video entity plus pose and retention enums. Pose extraction and retention enforcement arrive
// with Phase 5; the schema and types exist from Phase 1 so export and backup cover them.

export type PoseStatus = 'none' | 'pending' | 'running' | 'done' | 'failed';

export const POSE_STATUSES: readonly PoseStatus[] = ['none', 'pending', 'running', 'done', 'failed'];

export type RetentionClass = 'ephemeral' | 'keep';

export const RETENTION_CLASSES: readonly RetentionClass[] = ['ephemeral', 'keep'];

export interface Video {
  id: string;
  sessionId: string | null;
  climbId: string | null;
  uri: string;
  width: number | null;
  height: number | null;
  durationMs: number | null;
  fps: number | null;
  poseStatus: PoseStatus;
  retentionClass: RetentionClass;
  createdAt: string;
}

export interface PoseKeypoint {
  id: string;
  videoId: string;
  tMs: number;
  score: number | null;
  // Flat normalized keypoint array. Encoding lands with the Phase 5 pose pipeline.
  keypointsJson: string;
}
