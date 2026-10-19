// Climb screen: create (id "new") and edit. Grade is a (scheme, level) pair, never a free string
// (US-9). Angle is nullable, 0 to 90 (US-10.2). Archiving keeps attempts; deleting a climb with
// attempts is blocked (US-26).

import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { Alert, ScrollView, Text } from 'react-native';

import { useAppRepositories, useLogbook } from '@/src/app/providers';
import type { Climb } from '@/src/domain/models/climb';
import type { GradeLevel } from '@/src/domain/models/grade';
import { Card, Chip, EmptyState, Field, PrimaryButton, Row, Screen, SectionTitle, SecondaryButton } from '@/src/ui/components';
import { useTheme } from '@/src/ui/theme';

export default function ClimbScreen() {
  const params = useLocalSearchParams<{ id: string }>();
  const climb_id = typeof params.id === 'string' ? params.id : '';
  const is_new = climb_id === 'new';
  const logbook = useLogbook();
  const repos = useAppRepositories();
  const { colors } = useTheme();
  const state = logbook();

  const [climb, setClimb] = useState<Climb | null>(null);
  const [attemptCount, setAttemptCount] = useState(0);
  const [name, setName] = useState('');
  const [schemeId, setSchemeId] = useState('v_scale');
  const [levelId, setLevelId] = useState<string | null>(null);
  const [angleText, setAngleText] = useState('');
  const [colorCircuit, setColorCircuit] = useState('');
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const load = async () => {
      if (is_new) {
        setSchemeId(await repos.grades.getDefaultSystemId());
        setLoaded(true);
        return;
      }
      const existing = await repos.climbs.get(climb_id);
      if (existing === null) {
        setLoaded(true);
        return;
      }
      setClimb(existing);
      setName(existing.name ?? '');
      setSchemeId(existing.gradeSystem);
      setLevelId(existing.gradeRaw);
      setAngleText(existing.angleDeg === null ? '' : String(existing.angleDeg));
      setColorCircuit(existing.colorCircuit ?? '');
      setAttemptCount(await repos.attempts.countByClimb(existing.id));
      setLoaded(true);
    };
    void load();
  }, [climb_id, is_new, repos]);

  const selected_scheme = state.gradeSystems.find((system) => system.id === schemeId) ?? null;

  const save = async () => {
    setError(null);
    const trimmed_angle = angleText.trim();
    let angle_deg: number | null = null;
    if (trimmed_angle !== '') {
      angle_deg = Number(trimmed_angle);
      if (!Number.isFinite(angle_deg) || angle_deg < 0 || angle_deg > 90) {
        setError('Angle must be a number from 0 to 90, or empty.');
        return;
      }
    }
    try {
      if (is_new) {
        const gym_id = state.selectedGymId;
        if (gym_id === null) {
          setError('Pick a gym on the Logbook tab first.');
          return;
        }
        await repos.climbs.create({
          gymId: gym_id,
          name: name.trim() === '' ? null : name.trim(),
          gradeSystem: schemeId,
          gradeRaw: levelId,
          colorCircuit: colorCircuit.trim() === '' ? null : colorCircuit.trim(),
          angleDeg: angle_deg,
        });
      } else if (climb !== null) {
        await repos.climbs.update(climb.id, {
          name: name.trim() === '' ? null : name.trim(),
          gradeSystem: schemeId,
          gradeRaw: levelId,
          colorCircuit: colorCircuit.trim() === '' ? null : colorCircuit.trim(),
          angleDeg: angle_deg,
        });
      }
      await logbook.getState().refreshClimbs();
      router.back();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    }
  };

  const toggle_archive = async () => {
    if (climb === null) {
      return;
    }
    if (climb.isArchived) {
      await repos.climbs.unarchive(climb.id);
    } else {
      await repos.climbs.archive(climb.id);
    }
    await logbook.getState().refreshClimbs();
    router.back();
  };

  const delete_climb = () => {
    if (climb === null) {
      return;
    }
    Alert.alert('Delete climb?', 'This only works when the climb has no attempts. Otherwise archive it.', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Delete',
        style: 'destructive',
        onPress: () => {
          void repos.climbs
            .delete(climb.id)
            .then(async () => {
              await logbook.getState().refreshClimbs();
              router.back();
            })
            .catch((caught: unknown) => {
              Alert.alert('Cannot delete', caught instanceof Error ? caught.message : String(caught));
            });
        },
      },
    ]);
  };

  if (!loaded) {
    return (
      <Screen>
        <EmptyState title="Loading" />
      </Screen>
    );
  }
  if (!is_new && climb === null) {
    return (
      <Screen>
        <EmptyState title="Climb not found" />
      </Screen>
    );
  }

  return (
    <Screen>
      <Field label="Name" value={name} onChangeText={setName} placeholder="For example: Blue V4 slab" />

      <SectionTitle>Grade scheme</SectionTitle>
      <Row>
        {state.gradeSystems.map((system) => (
          <Chip key={system.id} label={system.name} selected={system.id === schemeId} onPress={() => {
            setSchemeId(system.id);
            setLevelId(null);
          }} />
        ))}
      </Row>

      <SectionTitle>Level</SectionTitle>
      {selected_scheme === null ? (
        <Text style={{ color: colors.textMuted }}>Scheme not found.</Text>
      ) : (
        <ScrollView horizontal showsHorizontalScrollIndicator={false}>
          <Row>
            {selected_scheme.levels.map((level: GradeLevel) => (
              <Chip
                key={level.id}
                label={level.label}
                selected={level.id === levelId}
                onPress={() => setLevelId(level.id === levelId ? null : level.id)}
              />
            ))}
          </Row>
        </ScrollView>
      )}

      <Field
        label="Wall angle in degrees (optional, 0 to 90)"
        value={angleText}
        onChangeText={setAngleText}
        keyboardType="numeric"
        placeholder="For example: 30"
      />
      <Field label="Color circuit (optional)" value={colorCircuit} onChangeText={setColorCircuit} placeholder="For example: blue" />

      {error === null ? null : <Text style={{ color: colors.danger }}>{error}</Text>}
      <PrimaryButton label={is_new ? 'Add climb' : 'Save changes'} onPress={() => void save()} />

      {is_new || climb === null ? null : (
        <>
          <SectionTitle>Manage</SectionTitle>
          <Card>
            <Text style={{ color: colors.textMuted }}>{attemptCount} logged attempts</Text>
            <SecondaryButton
              label={climb.isArchived ? 'Unarchive climb' : 'Archive climb'}
              onPress={() => void toggle_archive()}
            />
            <SecondaryButton label="Delete climb" tone="danger" onPress={delete_climb} />
          </Card>
        </>
      )}
    </Screen>
  );
}
