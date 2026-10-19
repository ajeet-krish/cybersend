// Compile time feature flag defaults per build variant. Phase 1 adds runtime overrides in the
// settings table (key flags.override); mergeFlags applies them over these defaults.

export type BuildVariant = 'development' | 'internal' | 'release';

export type FlagName =
  | 'video_capture'
  | 'grade_normalization'
  | 'ai_hold_detection'
  | 'ai_pose_analysis'
  | 'boulder_vision'
  | 'board_import';

export type FlagValues = Record<FlagName, boolean>;

// AI flags ship off in every variant and toggle on from the hidden dev screen.
// board_import stays dormant with the board seam (docs/decisions.md).
const default_flags: Record<BuildVariant, FlagValues> = {
  development: {
    video_capture: true,
    grade_normalization: true,
    ai_hold_detection: false,
    ai_pose_analysis: false,
    boulder_vision: true,
    board_import: false,
  },
  internal: {
    video_capture: true,
    grade_normalization: true,
    ai_hold_detection: false,
    ai_pose_analysis: false,
    boulder_vision: true,
    board_import: false,
  },
  release: {
    video_capture: false,
    grade_normalization: false,
    ai_hold_detection: false,
    ai_pose_analysis: false,
    boulder_vision: false,
    board_import: false,
  },
};

export function defaultFlags(variant: BuildVariant): FlagValues {
  return { ...default_flags[variant] };
}

export function mergeFlags(defaults: FlagValues, overrides: Partial<FlagValues>): FlagValues {
  return { ...defaults, ...overrides };
}

// Reads the variant injected by app.config.ts; unknown or missing values fall back to development.
export function readBuildVariant(extra: Record<string, unknown> | undefined): BuildVariant {
  const raw = extra?.buildVariant;
  if (raw === 'development' || raw === 'internal' || raw === 'release') {
    return raw;
  }
  return 'development';
}
