// Logbook tab: gym picker, active session entry, and the climb list that feeds quick logging
// (F1). Archived gyms stay visible here with a muted badge (US-8.4).

import { router } from 'expo-router';
import { useEffect } from 'react';
import { Pressable, StyleSheet, Text } from 'react-native';

import { useLogbook } from '@/src/app/providers';
import { grade_label } from '@/src/domain/models/grade';
import { Card, Chip, EmptyState, PrimaryButton, Row, Screen, SectionTitle, SecondaryButton } from '@/src/ui/components';
import { useTheme } from '@/src/ui/theme';

export default function LogbookScreen() {
  const logbook = useLogbook();
  const { colors } = useTheme();
  const state = logbook();

  useEffect(() => {
    void logbook.getState().refreshGyms();
    void logbook.getState().refreshSessions();
  }, [logbook]);

  const active_gyms = state.gyms.filter((gym) => gym.isActive);
  const selected_gym = state.gyms.find((gym) => gym.id === state.selectedGymId) ?? null;

  return (
    <Screen>
      <SectionTitle>Gym</SectionTitle>
      <Row>
        {active_gyms.map((gym) => (
          <Chip
            key={gym.id}
            label={gym.name}
            selected={gym.id === state.selectedGymId}
            onPress={() => void logbook.getState().selectGym(gym.id)}
          />
        ))}
        <Chip label="Manage" onPress={() => router.push('/gyms')} />
      </Row>
      {selected_gym !== null && selected_gym.isActive ? null : (
        <Text style={{ color: colors.textMuted }}>No gym selected yet.</Text>
      )}

      <SectionTitle>Session</SectionTitle>
      {state.activeSession === null ? (
        <Card>
          <Text style={{ color: colors.text }}>
            {selected_gym === null ? 'Pick a gym to start a session.' : `Start a session at ${selected_gym.name}.`}
          </Text>
          <PrimaryButton
            label="Start session"
            disabled={selected_gym === null || !selected_gym.isActive}
            onPress={() => {
              if (selected_gym !== null) {
                void logbook.getState().startSession(selected_gym.id).then((session) => {
                  if (session !== null) {
                    router.push(`/session/${session.id}`);
                  }
                });
              }
            }}
          />
        </Card>
      ) : (
        <Card>
          <Text style={{ color: colors.text }}>
            Session in progress at {state.gyms.find((gym) => gym.id === state.activeSession?.gymId)?.name ?? 'gym'}.
          </Text>
          <PrimaryButton label="Open session" onPress={() => router.push(`/session/${state.activeSession?.id ?? ''}`)} />
        </Card>
      )}

      <SectionTitle>Climbs</SectionTitle>
      {state.quickLogClimbs.length === 0 ? (
        <EmptyState
          title="No climbs yet"
          hint={selected_gym === null ? 'Pick a gym, then add your first climb.' : 'Add the climbs on the wall to start logging attempts.'}
        />
      ) : (
        <Card>
          {state.quickLogClimbs.map((climb) => {
            const system = state.gradeSystems.find((candidate) => candidate.id === climb.gradeSystem) ?? null;
            return (
              <Pressable key={climb.id} onPress={() => router.push(`/climb/${climb.id}`)} style={styles.climb_row}>
                <Text style={{ color: colors.text, fontWeight: '500' }}>{climb.name ?? 'Unnamed climb'}</Text>
                <Text style={{ color: colors.textMuted }}>{grade_label(system, climb.gradeRaw) ?? 'No grade'}</Text>
              </Pressable>
            );
          })}
        </Card>
      )}
      <Row>
        <SecondaryButton label="Add climb" onPress={() => router.push('/climb/new')} />
        <SecondaryButton label="Grade schemes" onPress={() => router.push('/grades')} />
      </Row>

      {state.error === null ? null : <Text style={{ color: colors.danger }}>{state.error}</Text>}
    </Screen>
  );
}

const styles = StyleSheet.create({
  climb_row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 8,
  },
});
