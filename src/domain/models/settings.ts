// Settings entity. Values are stored as JSON text in the settings table (key, value_json).

export interface SettingEntry {
  key: string;
  valueJson: string;
  updatedAt: string;
}

// Keys shared across layers.
export const SETTINGS_KEY_FLAG_OVERRIDES = 'flags.override';
export const SETTINGS_KEY_DEFAULT_GYM_ID = 'gym.default_id';
export const SETTINGS_KEY_GRADE_SCHEMES = 'grade.schemes';
export const SETTINGS_KEY_DEFAULT_GRADE_SYSTEM = 'grade.default_scheme';
export const SETTINGS_KEY_LAST_BACKUP_AT = 'backup.last_automatic_at';
