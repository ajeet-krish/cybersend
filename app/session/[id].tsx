// Session screen: live quick logging for an open session and a read only detail for closed ones.
// Quick log budget: pick climb, tap outcome, optionally pick the fall hold (F1, US-12.5).
// Closing collects a session level RPE 1 to 10 (US-11) and triggers an automatic backup (US-15).

import { router, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { Alert, Modal, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAppRepositories, useLogbook } from '@/src/app/providers';
import type { Attempt, AttemptOutcome } from '@/src/domain/models/attempt';
import type { Climb } from '@/src/domain/models/climb';
import type { Hold } from '@/src/domain/models/hold';
import type { Session } from '@/src/domain/models/session';
import { MAX_RPE, MIN_RPE } from '@/src/domain/models/session';
import { maybe_write_automatic_backup } from '@/src/features/backup/backup_service';
import { Card, Chip, EmptyState, Field, PrimaryButton, Row, Screen, SectionTitle, SecondaryButton } from '@/src/ui/components';
import { useTheme } from '@/src/ui/theme';

const OUTCOME_BUTTONS: readonly { outcome: AttemptOutcome; label: string }[] = [
  { outcome: 'flash', label: 'Flash' },
  { outcome: 'send', label: 'Send' },
  { outcome: 'project', label: 'Project' },
  { outcome: 'fail', label: 'Fail' },
];

export default function SessionScreen() {
  const params = useLocalSearchParams<{ id: string }>();
  const session_id = typeof params.id === 'string' ? params.id : '';
  const logbook = useLogbook();
  const repos = useAppRepositories();
  const { colors } = useTheme();
  const state = logbook();

  const [session, setSession] = useState<Session | null>(null);
  const [attempts, setAttempts] = useState<Attempt[]>([]);
  const [climbs, setClimbs] = useState<Climb[]>([]);
  const [selectedClimbId, setSelectedClimbId] = useState<string | null>(null);
  const [fallSheetOpen, setFallSheetOpen] = useState(false);
  const [pendingOutcome, setPendingOutcome] = useState<AttemptOutcome | null>(null);
  const [pendingHolds, setPendingHolds] = useState<Hold[]>([]);
  const [rpeSheetOpen, setRpeSheetOpen] = useState(false);
  const [rpe, setRpe] = useState<number | null>(null);
  const [notes, setNotes] = useState('');
  const [message, setMessage] = useState<string | null>(null);
  const [holdsByClimb, setHoldsByClimb] = useState<Record<string, Hold[]>>({});

  const reload = useCallback(async () => {
    const loaded = await repos.sessions.get(session_id);
    setSession(loaded);
    const loaded_attempts = await repos.attempts.listBySession(session_id);
    setAttempts(loaded_attempts);
    if (loaded !== null) {
      const loaded_climbs = await repos.climbs.list({ gymId: loaded.gymId });
      setClimbs(loaded_climbs);
      const hold_entries: Record<string, Hold[]> = {};
      for (const climb_id of new Set(loaded_attempts.map((attempt) => attempt.climbId))) {
        hold_entries[climb_id] = await repos.holds.listByClimb(climb_id);
      }
      setHoldsByClimb(hold_entries);
    }
  }, [repos, session_id]);

  useEffect(() => {
    void reload();
  }, [reload]);

  const climb_name = (climb_id: string): string => climbs.find((climb) => climb.id === climb_id)?.name ?? 'Unnamed climb';

  const hold_label = (hold: Hold, index: number): string => hold.label ?? hold.color ?? `Hold ${index + 1}`;

  const describe_fall = (fall_hold_id: string): string => {
    for (const holds of Object.values(holdsByClimb)) {
      const index = holds.findIndex((hold) => hold.id === fall_hold_id);
      const hold = index >= 0 ? holds[index] : undefined;
      if (hold !== undefined) {
        return hold_label(hold, index);
      }
    }
    return 'a hold';
  };

  const log_outcome = async (outcome: AttemptOutcome, fellOnHoldId: string | null) => {
    if (selectedClimbId === null) {
      setMessage('Pick a climb first.');
      return;
    }
    const result = await logbook.getState().logAttempt({ climbId: selectedClimbId, outcome, fellOnHoldId });
    setAttempts(await repos.attempts.listBySession(session_id));
    if (result === null) {
      setMessage(null);
    } else if (result === 'outcome_records_no_fall_hold') {
      setMessage('Logged. Sends do not record a fall hold.');
    } else {
      setMessage(result);
    }
  };

  const handle_outcome = async (outcome: AttemptOutcome) => {
    if (selectedClimbId === null) {
      setMessage('Pick a climb first.');
      return;
    }
    if (outcome === 'project' || outcome === 'fail') {
      const holds = await repos.holds.listByClimb(selectedClimbId);
      if (holds.length > 0) {
        setPendingHolds(holds);
        setPendingOutcome(outcome);
        setFallSheetOpen(true);
        return;
      }
    }
    await log_outcome(outcome, null);
  };

  const close_session = async () => {
    const closed = await logbook.getState().closeActiveSession({ rpe, notes: notes.trim() === '' ? null : notes.trim() });
    setRpeSheetOpen(false);
    if (closed !== null) {
      await reload();
      maybe_write_automatic_backup(repos, 'session_close').catch(() => setMessage('Session closed, but the backup failed.'));
    }
  };

  const delete_session = () => {
    Alert.alert('Delete session?', 'This removes the session and every attempt in it. This cannot be undone.', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Delete',
        style: 'destructive',
        onPress: () => {
          void repos.sessions.delete(session_id).then(() => router.back());
        },
      },
    ]);
  };

  if (session === null) {
    return (
      <Screen>
        <EmptyState title="Session not found" />
      </Screen>
    );
  }

  const is_open = session.endedAt === null;
  const grouped = new Map<string, Attempt[]>();
  for (const attempt of attempts) {
    const bucket = grouped.get(attempt.climbId) ?? [];
    bucket.push(attempt);
    grouped.set(attempt.climbId, bucket);
  }

  return (
    <Screen>
      <Card>
        <Text style={{ color: colors.text, fontSize: 16, fontWeight: '600' }}>
          {state.gyms.find((gym) => gym.id === session.gymId)?.name ?? 'Session'}
        </Text>
        <Text style={{ color: colors.textMuted }}>
          {session.startedAt.slice(0, 16).replace('T', ' ')}
          {session.endedAt === null ? ' to now' : ` to ${session.endedAt.slice(0, 16).replace('T', ' ')}`}
        </Text>
        {session.rpe === null ? null : <Text style={{ color: colors.text }}>RPE {session.rpe}</Text>}
        {session.notes === null ? null : <Text style={{ color: colors.textMuted }}>{session.notes}</Text>}
      </Card>

      {is_open ? (
        <>
          <SectionTitle>Quick log</SectionTitle>
          <ScrollView horizontal showsHorizontalScrollIndicator={false}>
            <Row>
              {climbs
                .filter((climb) => climb.isActive && !climb.isArchived)
                .map((climb) => (
                  <Chip
                    key={climb.id}
                    label={climb.name ?? 'Unnamed'}
                    selected={climb.id === selectedClimbId}
                    onPress={() => setSelectedClimbId(climb.id)}
                  />
                ))}
            </Row>
          </ScrollView>
          <Row>
            {OUTCOME_BUTTONS.map((button) => (
              <View key={button.outcome} style={styles.outcome_button}>
                <SecondaryButton label={button.label} onPress={() => void handle_outcome(button.outcome)} />
              </View>
            ))}
          </Row>
          {message === null ? null : <Text style={{ color: colors.warning }}>{message}</Text>}
          <PrimaryButton label="Close session" onPress={() => setRpeSheetOpen(true)} />
        </>
      ) : null}

      <SectionTitle>Attempts</SectionTitle>
      {attempts.length === 0 ? (
        <EmptyState title="No attempts yet" hint="Pick a climb and tap an outcome to log your first try." />
      ) : (
        [...grouped.entries()].map(([climb_id, climb_attempts]) => (
          <Card key={climb_id}>
            <Text style={{ color: colors.text, fontWeight: '600' }}>{climb_name(climb_id)}</Text>
            {climb_attempts.map((attempt) => (
              <Text key={attempt.id} style={{ color: colors.textMuted }}>
                #{attempt.attemptNo} {attempt.outcome}
                {attempt.fellOnHoldId === null ? '' : ` (fell on ${describe_fall(attempt.fellOnHoldId)})`}
              </Text>
            ))}
          </Card>
        ))
      )}

      {is_open ? null : (
        <Row>
          <SecondaryButton label="Delete session" tone="danger" onPress={delete_session} />
          <SecondaryButton label="Back" onPress={() => router.back()} />
        </Row>
      )}

      {/* Fall hold picker for project and fail outcomes. */}
      <Modal visible={fallSheetOpen} transparent animationType="slide" onRequestClose={() => setFallSheetOpen(false)}>
        <View style={styles.sheet_backdrop}>
          <View style={[styles.sheet, { backgroundColor: colors.surface }]}>
            <Text style={[styles.sheet_title, { color: colors.text }]}>Where did you fall?</Text>
            <ScrollView>
              <Row>
                {pendingHolds.map((hold, index) => (
                  <Chip
                    key={hold.id}
                    label={hold_label(hold, index)}
                    onPress={() => {
                      const outcome = pendingOutcome ?? 'fail';
                      setFallSheetOpen(false);
                      void log_outcome(outcome, hold.id);
                    }}
                  />
                ))}
              </Row>
            </ScrollView>
            <SecondaryButton
              label="Skip"
              onPress={() => {
                const outcome = pendingOutcome ?? 'fail';
                setFallSheetOpen(false);
                void log_outcome(outcome, null);
              }}
            />
          </View>
        </View>
      </Modal>

      {/* RPE entry on session close. */}
      <Modal visible={rpeSheetOpen} transparent animationType="slide" onRequestClose={() => setRpeSheetOpen(false)}>
        <View style={styles.sheet_backdrop}>
          <View style={[styles.sheet, { backgroundColor: colors.surface }]}>
            <Text style={[styles.sheet_title, { color: colors.text }]}>How hard was it? (RPE {MIN_RPE} to {MAX_RPE})</Text>
            <Row>
              {Array.from({ length: MAX_RPE - MIN_RPE + 1 }, (_unused, index) => MIN_RPE + index).map((value) => (
                <Chip key={value} label={String(value)} selected={rpe === value} onPress={() => setRpe(value)} />
              ))}
            </Row>
            <Field label="Notes" value={notes} onChangeText={setNotes} multiline placeholder="Optional" />
            <PrimaryButton label="Close session" disabled={rpe === null} onPress={() => void close_session()} />
            <SecondaryButton label="Cancel" onPress={() => setRpeSheetOpen(false)} />
          </View>
        </View>
      </Modal>
    </Screen>
  );
}

const styles = StyleSheet.create({
  outcome_button: {
    flex: 1,
    minWidth: 76,
    margin: 4,
  },
  sheet_backdrop: {
    flex: 1,
    justifyContent: 'flex-end',
    backgroundColor: 'rgba(0, 0, 0, 0.4)',
  },
  sheet: {
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    padding: 20,
    gap: 12,
    maxHeight: '80%',
  },
  sheet_title: {
    fontSize: 16,
    fontWeight: '600',
  },
});
