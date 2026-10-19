import type { PoseKeypoint, PoseStatus, RetentionClass, Video } from '../../domain/models/video';
import { POSE_STATUSES, RETENTION_CLASSES } from '../../domain/models/video';
import type { SqlRow, SqlValue } from '../db/executor';
import { row_int, row_opt_int, row_opt_real, row_opt_text, row_text } from './common';

function parse_pose_status(raw: string): PoseStatus {
  if ((POSE_STATUSES as readonly string[]).includes(raw)) {
    return raw as PoseStatus;
  }
  throw new Error(`Unknown pose status in database: ${raw}`);
}

function parse_retention_class(raw: string): RetentionClass {
  if ((RETENTION_CLASSES as readonly string[]).includes(raw)) {
    return raw as RetentionClass;
  }
  throw new Error(`Unknown retention class in database: ${raw}`);
}

export function row_to_video(row: SqlRow): Video {
  return {
    id: row_text(row, 'id'),
    sessionId: row_opt_text(row, 'session_id'),
    climbId: row_opt_text(row, 'climb_id'),
    uri: row_text(row, 'uri'),
    width: row_opt_int(row, 'width'),
    height: row_opt_int(row, 'height'),
    durationMs: row_opt_int(row, 'duration_ms'),
    fps: row_opt_real(row, 'fps'),
    poseStatus: parse_pose_status(row_text(row, 'pose_status')),
    retentionClass: parse_retention_class(row_text(row, 'retention_class')),
    createdAt: row_text(row, 'created_at'),
  };
}

export function video_to_row(video: Video): Record<string, SqlValue> {
  return {
    id: video.id,
    session_id: video.sessionId,
    climb_id: video.climbId,
    uri: video.uri,
    width: video.width,
    height: video.height,
    duration_ms: video.durationMs,
    fps: video.fps,
    pose_status: video.poseStatus,
    retention_class: video.retentionClass,
    created_at: video.createdAt,
  };
}

export function row_to_pose_keypoint(row: SqlRow): PoseKeypoint {
  return {
    id: row_text(row, 'id'),
    videoId: row_text(row, 'video_id'),
    tMs: row_int(row, 't_ms'),
    score: row_opt_real(row, 'score'),
    keypointsJson: row_text(row, 'keypoints_json'),
  };
}

export function pose_keypoint_to_row(keypoint: PoseKeypoint): Record<string, SqlValue> {
  return {
    id: keypoint.id,
    video_id: keypoint.videoId,
    t_ms: keypoint.tMs,
    score: keypoint.score,
    keypoints_json: keypoint.keypointsJson,
  };
}
