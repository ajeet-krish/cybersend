// Sessions tab: reverse chronological history with gym, date, RPE, and attempt counts (US-22.1).
// Tapping a row opens the session detail at /session/[id].

import { router } from 'expo-router';
import { useEffect } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { useLogbook } from '@/src/app/providers';
import { Card, EmptyState, Screen, SectionTitle } from '@/src/ui/components';
import { useTheme } from '@/src/ui/theme';

export default function SessionsScreen() {
  const logbook = useLogbook();
  const { colors } = useTheme();
  const state = logbook();

  useEffect(() => {
    void logbook.getState().refreshSessions();
  }, [logbook]);

  return (
    <Screen>
      <SectionTitle>History</SectionTitle>
      {state.recentSessions.length === 0 ? (
        <EmptyState title="No sessions yet" hint="Sessions appear here after you log one from the Logbook tab." />
      ) : (
        <Card>
          {state.recentSessions.map((session) => {
            const gym = state.gyms.find((candidate) => candidate.id === session.gymId);
            return (
              <Pressable key={session.id} onPress={() => router.push(`/session/${session.id}`)} style={styles.row}>
                <View>
                  <Text style={{ color: colors.text, fontWeight: '500' }}>
                    {gym?.name ?? 'Unknown gym'}
                    {session.endedAt === null ? ' (open)' : ''}
                  </Text>
                  <Text style={{ color: colors.textMuted }}>{session.startedAt.slice(0, 10)}</Text>
                </View>
                <View style={styles.right}>
                  <Text style={{ color: colors.textMuted }}>{session.attemptCount} attempts</Text>
                  <Text style={{ color: colors.text }}>{session.rpe === null ? 'No RPE' : `RPE ${session.rpe}`}</Text>
                </View>
              </Pressable>
            );
          })}
        </Card>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: 8,
  },
  right: {
    alignItems: 'flex-end',
    gap: 2,
  },
});
