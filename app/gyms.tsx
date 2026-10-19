// Gym management: create, rename, archive (US-8). Duplicate names are allowed and disambiguated
// by creation date (US-8.3); archived gyms are hidden from new sessions but stay in history.

import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { Alert, StyleSheet, Text, View } from 'react-native';

import { useAppRepositories, useLogbook } from '@/src/app/providers';
import type { Gym } from '@/src/domain/models/gym';
import { Card, EmptyState, Field, PrimaryButton, Row, Screen, SectionTitle, SecondaryButton } from '@/src/ui/components';
import { useTheme } from '@/src/ui/theme';

export default function GymsScreen() {
  const logbook = useLogbook();
  const repos = useAppRepositories();
  const { colors } = useTheme();
  const state = logbook();
  const [newName, setNewName] = useState('');
  const [actionError, setActionError] = useState<string | null>(null);

  useEffect(() => {
    void logbook.getState().refreshGyms();
  }, [logbook]);

  const run = async (action: () => Promise<void>) => {
    try {
      await action();
      setActionError(null);
    } catch (error) {
      setActionError(error instanceof Error ? error.message : String(error));
    }
  };

  const add_gym = () => {
    const trimmed = newName.trim();
    if (trimmed === '') {
      return;
    }
    void run(async () => {
      await repos.gyms.create({ name: trimmed });
      setNewName('');
      await logbook.getState().refreshGyms();
    });
  };

  const rename_gym = (gym: Gym) => {
    Alert.prompt('Rename gym', gym.name, (text) => {
      if (text === undefined || text.trim() === '') {
        return;
      }
      void run(async () => {
        await repos.gyms.rename(gym.id, text);
        await logbook.getState().refreshGyms();
      });
    });
  };

  const toggle_archive = (gym: Gym) => {
    void run(async () => {
      if (gym.isActive) {
        await repos.gyms.archive(gym.id);
      } else {
        await repos.gyms.unarchive(gym.id);
      }
      await logbook.getState().refreshGyms();
    });
  };

  return (
    <Screen>
      <SectionTitle>Add gym</SectionTitle>
      <Field label="Gym name" value={newName} onChangeText={setNewName} placeholder="Duplicate names are fine" />
      <PrimaryButton label="Add gym" onPress={add_gym} />

      <SectionTitle>All gyms</SectionTitle>
      {state.gyms.length === 0 ? (
        <EmptyState title="No gyms yet" hint="Add the gym you climb at to start logging sessions." />
      ) : (
        state.gyms.map((gym) => (
          <Card key={gym.id}>
            <View style={styles.header_row}>
              <Text style={{ color: colors.text, fontWeight: '600' }}>
                {gym.name}
                {gym.isActive ? '' : ' (archived)'}
              </Text>
              <Text style={{ color: colors.textMuted }}>{gym.createdAt.slice(0, 10)}</Text>
            </View>
            <Row>
              <SecondaryButton label="Rename" onPress={() => rename_gym(gym)} />
              <SecondaryButton label={gym.isActive ? 'Archive' : 'Unarchive'} onPress={() => toggle_archive(gym)} />
              {gym.isActive ? (
                <SecondaryButton
                  label="Select"
                  onPress={() => {
                    void logbook.getState().selectGym(gym.id);
                    router.back();
                  }}
                />
              ) : null}
            </Row>
          </Card>
        ))
      )}

      {actionError === null ? null : <Text style={{ color: colors.danger }}>{actionError}</Text>}
    </Screen>
  );
}

const styles = StyleSheet.create({
  header_row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
});
