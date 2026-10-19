import { defaultFlags, mergeFlags, readBuildVariant } from '../flags';

describe('feature flag defaults', () => {
  test('AI flags and board_import are off in every variant', () => {
    for (const variant of ['development', 'internal', 'release'] as const) {
      const flags = defaultFlags(variant);
      expect(flags.ai_hold_detection).toBe(false);
      expect(flags.ai_pose_analysis).toBe(false);
      expect(flags.board_import).toBe(false);
    }
  });

  test('boulder_vision is on outside release only', () => {
    expect(defaultFlags('development').boulder_vision).toBe(true);
    expect(defaultFlags('internal').boulder_vision).toBe(true);
    expect(defaultFlags('release').boulder_vision).toBe(false);
  });
});

describe('mergeFlags', () => {
  test('overrides win over defaults without mutating them', () => {
    const defaults = defaultFlags('release');
    const merged = mergeFlags(defaults, { ai_hold_detection: true });
    expect(merged.ai_hold_detection).toBe(true);
    expect(merged.boulder_vision).toBe(false);
    expect(defaults.ai_hold_detection).toBe(false);
  });
});

describe('readBuildVariant', () => {
  test('reads a known variant from extra', () => {
    expect(readBuildVariant({ buildVariant: 'internal' })).toBe('internal');
    expect(readBuildVariant({ buildVariant: 'release' })).toBe('release');
  });

  test('missing or unknown values fall back to development', () => {
    expect(readBuildVariant(undefined)).toBe('development');
    expect(readBuildVariant({})).toBe('development');
    expect(readBuildVariant({ buildVariant: 'bogus' })).toBe('development');
  });
});
