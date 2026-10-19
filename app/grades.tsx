// Grade scheme management (US-9): V scale and Font are built in, custom schemes are named ordered
// levels, and deleting a scheme in use is blocked by the repository.

import { useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { useAppRepositories, useLogbook } from '@/src/app/providers';
import { Card, Field, PrimaryButton, Row, Screen, SectionTitle, SecondaryButton } from '@/src/ui/components';
import { useTheme } from '@/src/ui/theme';

export default function GradesScreen() {
  const logbook = useLogbook();
  const repos = useAppRepositories();
  const { colors } = useTheme();
  const state = logbook();
  const [schemeName, setSchemeName] = useState('');
  const [levelLabels, setLevelLabels] = useState('');
  const [actionError, setActionError] = useState<string | null>(null);

  const run = async (action: () => Promise<void>) => {
    try {
      await action();
      setActionError(null);
    } catch (error) {
      setActionError(error instanceof Error ? error.message : String(error));
    }
  };

  const refresh = async () => {
    await run(async () => {
      const systems = await repos.grades.listSystems();
      logbook.setState({ gradeSystems: systems });
    });
  };

  useEffect(() => {
    void refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const create_scheme = () => {
    const labels = levelLabels
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line !== '');
    void run(async () => {
      await repos.grades.createCustomSystem({ name: schemeName, levelLabels: labels });
      setSchemeName('');
      setLevelLabels('');
      await refresh();
    });
  };

  const delete_scheme = (systemId: string) => {
    void run(async () => {
      await repos.grades.deleteCustomSystem(systemId);
      await refresh();
    });
  };

  return (
    <Screen>
      <SectionTitle>Built in and custom schemes</SectionTitle>
      {state.gradeSystems.map((system) => (
        <Card key={system.id}>
          <View style={styles.header_row}>
            <Text style={{ color: colors.text, fontWeight: '600' }}>
              {system.name}
              {system.isBuiltin ? ' (built in)' : ''}
            </Text>
            <Text style={{ color: colors.textMuted }}>{system.levels.length} levels</Text>
          </View>
          <Text style={{ color: colors.textMuted }}>{system.levels.map((level) => level.label).join(', ')}</Text>
          {system.isBuiltin ? null : (
            <Row>
              <SecondaryButton label="Delete" tone="danger" onPress={() => delete_scheme(system.id)} />
            </Row>
          )}
        </Card>
      ))}

      <SectionTitle>New custom scheme</SectionTitle>
      <Field label="Scheme name" value={schemeName} onChangeText={setSchemeName} placeholder="For example: My gym colors" />
      <Field
        label="Levels, one per line, low to high"
        value={levelLabels}
        onChangeText={setLevelLabels}
        multiline
        numberOfLines={5}
        placeholder={'green\nblue\nblack'}
      />
      <PrimaryButton label="Create scheme" onPress={create_scheme} />

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
