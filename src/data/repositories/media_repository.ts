// Media repository: photos, videos, and pose keypoint rows. Capture and tagging flows arrive in
// Phase 2 and Phase 5; the repository exists from Phase 1 so backup export covers every table.

import type { Photo, PhotoSource } from '../../domain/models/photo';
import type { PoseKeypoint, RetentionClass, Video, PoseStatus } from '../../domain/models/video';
import type { SqlExecutor } from '../db/executor';
import { generate_id } from '../id';
import { photo_to_row, pose_keypoint_to_row, row_to_photo, row_to_pose_keypoint, row_to_video, video_to_row } from '../mappers';
import { now_iso } from '../time';

export interface CreatePhotoInput {
  uri: string;
  width: number;
  height: number;
  climbId?: string | null;
  sessionId?: string | null;
  thumbUri?: string | null;
  source?: PhotoSource;
  capturedAt?: string;
}

export interface CreateVideoInput {
  uri: string;
  sessionId?: string | null;
  climbId?: string | null;
  width?: number | null;
  height?: number | null;
  durationMs?: number | null;
  fps?: number | null;
  poseStatus?: PoseStatus;
  retentionClass?: RetentionClass;
}

export interface ListVideosOptions {
  sessionId?: string;
  climbId?: string;
  retentionClass?: RetentionClass;
}

export class MediaRepository {
  private readonly executor: SqlExecutor;

  constructor(executor: SqlExecutor) {
    this.executor = executor;
  }

  // Photos.

  async createPhoto(input: CreatePhotoInput): Promise<Photo> {
    const photo: Photo = {
      id: generate_id(),
      climbId: input.climbId ?? null,
      sessionId: input.sessionId ?? null,
      uri: input.uri,
      thumbUri: input.thumbUri ?? null,
      width: input.width,
      height: input.height,
      source: input.source ?? 'camera',
      capturedAt: input.capturedAt ?? now_iso(),
      createdAt: now_iso(),
    };
    const row = photo_to_row(photo);
    await this.executor.execute(
      `INSERT INTO photos (id, climb_id, session_id, uri, thumb_uri, width, height, source, captured_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      Object.values(row),
    );
    return photo;
  }

  async getPhoto(id: string): Promise<Photo | null> {
    const row = await this.executor.prepare('SELECT * FROM photos WHERE id = ?').get([id]);
    return row === null ? null : row_to_photo(row);
  }

  async listPhotos(filter: { climbId?: string; sessionId?: string } = {}): Promise<Photo[]> {
    const clauses: string[] = [];
    const params: string[] = [];
    if (filter.climbId !== undefined) {
      clauses.push('climb_id = ?');
      params.push(filter.climbId);
    }
    if (filter.sessionId !== undefined) {
      clauses.push('session_id = ?');
      params.push(filter.sessionId);
    }
    const where = clauses.length > 0 ? `WHERE ${clauses.join(' AND ')}` : '';
    const result = await this.executor.prepare(`SELECT * FROM photos ${where} ORDER BY captured_at DESC`).all(params);
    return result.map(row_to_photo);
  }

  async updatePhotoThumb(id: string, thumbUri: string | null): Promise<void> {
    await this.executor.execute('UPDATE photos SET thumb_uri = ? WHERE id = ?', [thumbUri, id]);
  }

  async deletePhoto(id: string): Promise<void> {
    await this.executor.execute('DELETE FROM photos WHERE id = ?', [id]);
  }

  // Videos.

  async createVideo(input: CreateVideoInput): Promise<Video> {
    const video: Video = {
      id: generate_id(),
      sessionId: input.sessionId ?? null,
      climbId: input.climbId ?? null,
      uri: input.uri,
      width: input.width ?? null,
      height: input.height ?? null,
      durationMs: input.durationMs ?? null,
      fps: input.fps ?? null,
      poseStatus: input.poseStatus ?? 'none',
      retentionClass: input.retentionClass ?? 'ephemeral',
      createdAt: now_iso(),
    };
    const row = video_to_row(video);
    await this.executor.execute(
      `INSERT INTO videos (id, session_id, climb_id, uri, width, height, duration_ms, fps, pose_status, retention_class, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      Object.values(row),
    );
    return video;
  }

  async getVideo(id: string): Promise<Video | null> {
    const row = await this.executor.prepare('SELECT * FROM videos WHERE id = ?').get([id]);
    return row === null ? null : row_to_video(row);
  }

  async listVideos(options: ListVideosOptions = {}): Promise<Video[]> {
    const clauses: string[] = [];
    const params: string[] = [];
    if (options.sessionId !== undefined) {
      clauses.push('session_id = ?');
      params.push(options.sessionId);
    }
    if (options.climbId !== undefined) {
      clauses.push('climb_id = ?');
      params.push(options.climbId);
    }
    if (options.retentionClass !== undefined) {
      clauses.push('retention_class = ?');
      params.push(options.retentionClass);
    }
    const where = clauses.length > 0 ? `WHERE ${clauses.join(' AND ')}` : '';
    const result = await this.executor.prepare(`SELECT * FROM videos ${where} ORDER BY created_at DESC`).all(params);
    return result.map(row_to_video);
  }

  async updateVideo(id: string, patch: { poseStatus?: PoseStatus; retentionClass?: RetentionClass }): Promise<void> {
    if (patch.poseStatus !== undefined) {
      await this.executor.execute('UPDATE videos SET pose_status = ? WHERE id = ?', [patch.poseStatus, id]);
    }
    if (patch.retentionClass !== undefined) {
      await this.executor.execute('UPDATE videos SET retention_class = ? WHERE id = ?', [patch.retentionClass, id]);
    }
  }

  async deleteVideo(id: string): Promise<void> {
    await this.executor.execute('DELETE FROM videos WHERE id = ?', [id]);
  }

  // Pose keypoints.

  async addPoseKeypoint(input: { videoId: string; tMs: number; score?: number | null; keypoints: readonly number[] | string }): Promise<PoseKeypoint> {
    const keypoint: PoseKeypoint = {
      id: generate_id(),
      videoId: input.videoId,
      tMs: input.tMs,
      score: input.score ?? null,
      keypointsJson: typeof input.keypoints === 'string' ? input.keypoints : JSON.stringify(input.keypoints),
    };
    const row = pose_keypoint_to_row(keypoint);
    await this.executor.execute(
      'INSERT INTO pose_keypoints (id, video_id, t_ms, score, keypoints_json) VALUES (?, ?, ?, ?, ?)',
      Object.values(row),
    );
    return keypoint;
  }

  async listPoseKeypoints(videoId: string): Promise<PoseKeypoint[]> {
    const result = await this.executor
      .prepare('SELECT * FROM pose_keypoints WHERE video_id = ? ORDER BY t_ms')
      .all([videoId]);
    return result.map(row_to_pose_keypoint);
  }
}
