// Table metadata and zod schemas for import payloads (docs/architecture.md: validation holds zod
// schemas for import payloads). Column lists mirror docs/schema.sql exactly; the import path
// rejects any row that does not match, so a corrupt or truncated file aborts with zero writes
// (US-16.3) and foreign payloads cannot smuggle extra columns.

import { z } from 'zod';

export type TableName =
  | 'gyms'
  | 'walls'
  | 'boards'
  | 'board_problems'
  | 'climbs'
  | 'holds'
  | 'sessions'
  | 'photos'
  | 'videos'
  | 'pose_keypoints'
  | 'attempts'
  | 'grade_norm_params'
  | 'settings';

export type ColumnType = 'text' | 'integer' | 'real';

export interface ColumnSpec {
  type: ColumnType;
  nullable: boolean;
}

const t = (type: ColumnType): ColumnSpec => ({ type, nullable: false });
const tn = (type: ColumnType): ColumnSpec => ({ type, nullable: true });

// Insert order: parents before children so FK checks pass during import.
export const TABLES_IN_INSERT_ORDER: readonly TableName[] = [
  'gyms',
  'walls',
  'boards',
  'board_problems',
  'climbs',
  'holds',
  'sessions',
  'photos',
  'videos',
  'pose_keypoints',
  'attempts',
  'grade_norm_params',
  'settings',
];

export const TABLE_COLUMNS: Record<TableName, Record<string, ColumnSpec>> = {
  gyms: {
    id: t('text'),
    name: t('text'),
    timezone: tn('text'),
    is_active: t('integer'),
    created_at: t('text'),
    updated_at: t('text'),
  },
  walls: {
    id: t('text'),
    gym_id: t('text'),
    name: tn('text'),
    angle_deg: tn('real'),
    angle_label: tn('text'),
    is_active: t('integer'),
    created_at: t('text'),
    updated_at: t('text'),
  },
  boards: {
    id: t('text'),
    provider: t('text'),
    name: t('text'),
    angle_deg: tn('real'),
    created_at: t('text'),
    updated_at: t('text'),
  },
  board_problems: {
    id: t('text'),
    board_id: t('text'),
    provider: t('text'),
    external_id: tn('text'),
    name: tn('text'),
    grade_raw: tn('text'),
    angle_deg: tn('real'),
    holds_json: t('text'),
    is_active: t('integer'),
    imported_at: t('text'),
  },
  climbs: {
    id: t('text'),
    gym_id: t('text'),
    wall_id: tn('text'),
    board_id: tn('text'),
    board_problem_id: tn('text'),
    name: tn('text'),
    grade_system: t('text'),
    grade_raw: tn('text'),
    grade_norm: tn('real'),
    color_circuit: tn('text'),
    angle_deg: tn('real'),
    is_active: t('integer'),
    is_archived: t('integer'),
    created_at: t('text'),
    updated_at: t('text'),
  },
  holds: {
    id: t('text'),
    climb_id: t('text'),
    x_norm: t('real'),
    y_norm: t('real'),
    radius_norm: t('real'),
    label: tn('text'),
    color: tn('text'),
    source: t('text'),
    ordinal: tn('integer'),
    created_at: t('text'),
    updated_at: t('text'),
  },
  sessions: {
    id: t('text'),
    gym_id: t('text'),
    started_at: t('text'),
    ended_at: tn('text'),
    rpe: tn('integer'),
    notes: tn('text'),
    created_at: t('text'),
    updated_at: t('text'),
  },
  photos: {
    id: t('text'),
    climb_id: tn('text'),
    session_id: tn('text'),
    uri: t('text'),
    thumb_uri: tn('text'),
    width: t('integer'),
    height: t('integer'),
    source: t('text'),
    captured_at: t('text'),
    created_at: t('text'),
  },
  videos: {
    id: t('text'),
    session_id: tn('text'),
    climb_id: tn('text'),
    uri: t('text'),
    width: tn('integer'),
    height: tn('integer'),
    duration_ms: tn('integer'),
    fps: tn('real'),
    pose_status: t('text'),
    retention_class: t('text'),
    created_at: t('text'),
  },
  pose_keypoints: {
    id: t('text'),
    video_id: t('text'),
    t_ms: t('integer'),
    score: tn('real'),
    keypoints_json: t('text'),
  },
  attempts: {
    id: t('text'),
    session_id: t('text'),
    climb_id: t('text'),
    attempt_no: t('integer'),
    outcome: t('text'),
    fell_on_hold_id: tn('text'),
    video_id: tn('text'),
    notes: tn('text'),
    created_at: t('text'),
  },
  grade_norm_params: {
    id: t('text'),
    scope: t('text'),
    gym_id: tn('text'),
    algo_version: t('text'),
    sample_count: t('integer'),
    params_json: t('text'),
    computed_at: t('text'),
  },
  settings: {
    key: t('text'),
    value_json: t('text'),
    updated_at: t('text'),
  },
};

export type ExportRow = Record<string, string | number | null>;

function column_schema(spec: ColumnSpec): z.ZodType<string | number | null> {
  if (spec.type === 'text') {
    return spec.nullable ? z.string().nullable() : z.string();
  }
  if (spec.type === 'integer') {
    return spec.nullable ? z.number().int().nullable() : z.number().int();
  }
  return spec.nullable ? z.number().nullable() : z.number();
}

export function table_schema(name: TableName): z.ZodType<ExportRow> {
  const shape: Record<string, z.ZodType<string | number | null>> = {};
  for (const [column, spec] of Object.entries(TABLE_COLUMNS[name])) {
    shape[column] = column_schema(spec);
  }
  return z.strictObject(shape);
}

export const export_payload_schema = z.strictObject({
  app: z.literal('cybersend'),
  schema_version: z.number().int().min(1),
  exported_at: z.string(),
  tables: z.strictObject({
    gyms: z.array(table_schema('gyms')),
    walls: z.array(table_schema('walls')),
    boards: z.array(table_schema('boards')),
    board_problems: z.array(table_schema('board_problems')),
    climbs: z.array(table_schema('climbs')),
    holds: z.array(table_schema('holds')),
    sessions: z.array(table_schema('sessions')),
    photos: z.array(table_schema('photos')),
    videos: z.array(table_schema('videos')),
    pose_keypoints: z.array(table_schema('pose_keypoints')),
    attempts: z.array(table_schema('attempts')),
    grade_norm_params: z.array(table_schema('grade_norm_params')),
    settings: z.array(table_schema('settings')),
  }),
});

export type ExportPayloadParsed = z.infer<typeof export_payload_schema>;
