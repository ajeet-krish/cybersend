// Hidden runtime flag screen for non release builds (docs/architecture.md feature flags).
// Toggles persist to the settings table (key flags.override) and merge over the variant defaults.

import { useEffect, useState } from 'react';
import { StyleSheet, Switch, Text, View } from 'react-native';

import { useAppContext } from '@/src/app/providers';
import { update_flag_override } from '@/src/app/di';
import type { FlagName } from '@/src/app/flags';
import { Card, EmptyState, Screen, SectionTitle } from '@/src/ui/components';
import { useTheme } from '@/src/ui/theme';

const FLAG_LABELS: Record<FlagName, string> = {
  video_capture: 'Video capture',
  grade_normalization: 'Grade normalization',
  ai_hold_detection: 'AI hold detection',
  ai_pose_analysis: 'AI pose analysis',
  boulder_vision: 'BoulderVision',
  board_import: 'Board import (dormant)',
};

export default function DevFlagsScreen() {
  const { container, setFlags } = useAppContext();
  const { colors } = useTheme();
  const [flags, setLocalFlags] = useState(container.flags);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setLocalFlags(container.flags);
  }, [container.flags]);

  if (container.buildVariant === 'release') {
    return (
      <Screen>
        <EmptyState title="Not available in release builds" />
      </Screen>
    );
  }

  const toggle = (name: FlagName, value: boolean) => {
    void update_flag_override(container.repos, name, value, flags)
      .then((merged) => {
        setLocalFlags(merged);
        setFlags(merged);
        setError(null);
      })
      .catch((caught: unknown) => setError(caught instanceof Error ? caught.message : String(caught)));
  };

  return (
    <Screen>
      <SectionTitle>Runtime overrides ({container.buildVariant})</SectionTitle>
      <Card>
        {(Object.keys(FLAG_LABELS) as FlagName[]).map((name) => (
          <View key={name} style={styles.row}>
            <Text style={{ color: colors.text }}>{FLAG_LABELS[name]}</Text>
            <Switch value={flags[name]} onValueChange={(value) => toggle(name, value)} />
          </View>
        ))}
      </Card>
      {error === null ? null : <Text style={{ color: colors.danger }}>{error}</Text>}
    </Screen>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: 6,
  },
});
