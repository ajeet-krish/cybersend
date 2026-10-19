// Settings tab: default gym, export and backup entry points (US-14, US-15, US-16), and the hidden
// feature flag screen on non release builds (docs/architecture.md feature flags).

import * as DocumentPicker from 'expo-document-picker';
import { router } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { Alert, Text } from 'react-native';
import { File } from 'expo-file-system';

import { useAppContext, useAppRepositories, useLogbook } from '@/src/app/providers';
import {
  build_export_csv,
  build_export_json,
  import_payload_json,
  list_backups,
  restore_backup,
  share_file,
  write_backup,
  write_export_csv,
  write_export_json,
  type CsvEntity,
} from '@/src/features/backup';
import { app_version } from '@/src/features/backup/export_service';
import { SETTINGS_KEY_DEFAULT_GYM_ID, SETTINGS_KEY_LAST_BACKUP_AT } from '@/src/domain/models/settings';
import { Card, Chip, PrimaryButton, Row, Screen, SectionTitle, SecondaryButton } from '@/src/ui/components';
import { useTheme } from '@/src/ui/theme';

export default function SettingsScreen() {
  const { container } = useAppContext();
  const repos = useAppRepositories();
  const logbook = useLogbook();
  const { colors } = useTheme();
  const state = logbook();
  const [defaultGymId, setDefaultGymId] = useState<string | null>(null);
  const [lastBackupAt, setLastBackupAt] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    await logbook.getState().refreshGyms();
    setDefaultGymId(await repos.settings.getJson<string>(SETTINGS_KEY_DEFAULT_GYM_ID));
    setLastBackupAt(await repos.settings.getJson<string>(SETTINGS_KEY_LAST_BACKUP_AT));
  }, [logbook, repos]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    try {
      await action();
    } catch (error) {
      setNote(error instanceof Error ? error.message : String(error));
    } finally {
      setBusy(false);
    }
  };

  const export_json = () =>
    run(async () => {
      const json = await build_export_json(repos);
      const uri = await write_export_json(json);
      await share_file(uri);
      setNote('JSON export ready to share.');
    });

  const export_csv = (entity: CsvEntity) =>
    run(async () => {
      const csv = await build_export_csv(repos, entity);
      const uri = await write_export_csv(csv, entity);
      await share_file(uri);
      setNote(`${entity} CSV ready to share.`);
    });

  const backup_now = () =>
    run(async () => {
      await write_backup(repos);
      setLastBackupAt(await repos.settings.getJson<string>(SETTINGS_KEY_LAST_BACKUP_AT));
      setNote('Backup written to the backups folder.');
    });

  const import_file = () =>
    run(async () => {
      const picked = await DocumentPicker.getDocumentAsync({ copyToCacheDirectory: true });
      if (picked.canceled || picked.assets.length === 0) {
        return;
      }
      const asset = picked.assets[0];
      if (asset === undefined) {
        return;
      }
      const file = new File(asset.uri);
      if (asset.name.endsWith('.cybersend')) {
        const result = await restore_backup({ executor: container.executor, repos }, file, {
          databasePath: db_path_of(container.executor),
        });
        const warning = result.warnings.length > 0 ? ` ${result.warnings.join(' ')}` : '';
        setNote(`Backup restored.${warning}`);
      } else {
        const report = await import_payload_json(await file.text(), { executor: container.executor, dump: repos.dump });
        setNote(
          `Import complete: ${Object.values(report.upserts).reduce((total, counts) => total + counts.inserted, 0)} rows added.`,
        );
      }
      await refresh();
      await logbook.getState().refreshGyms();
      await logbook.getState().refreshSessions();
    });

  const restore_from_backup = () =>
    run(async () => {
      const backups = await list_backups();
      if (backups.length === 0) {
        setNote('No local backups yet.');
        return;
      }
      Alert.alert(
        'Restore backup',
        `Restore the newest of ${backups.length} local backups? Your current data is replaced.`,
        [
          { text: 'Cancel', style: 'cancel' },
          {
            text: 'Restore',
            style: 'destructive',
            onPress: () => {
              const newest = backups[0];
              if (newest === undefined) {
                return;
              }
              void run(async () => {
                const result = await restore_backup({ executor: container.executor, repos }, new File(newest.uri), {
                  databasePath: db_path_of(container.executor),
                });
                const warning = result.warnings.length > 0 ? ` ${result.warnings.join(' ')}` : '';
                setNote(`Backup restored.${warning}`);
                await refresh();
              });
            },
          },
        ],
      );
    });

  return (
    <Screen>
      <SectionTitle>Defaults</SectionTitle>
      <Card>
        <Text style={{ color: colors.textMuted }}>Default gym</Text>
        <Row>
          {state.gyms
            .filter((gym) => gym.isActive)
            .map((gym) => (
              <Chip
                key={gym.id}
                label={gym.name}
                selected={gym.id === defaultGymId}
                onPress={() =>
                  void run(async () => {
                    await repos.settings.setJson(SETTINGS_KEY_DEFAULT_GYM_ID, gym.id);
                    setDefaultGymId(gym.id);
                  })
                }
              />
            ))}
        </Row>
      </Card>

      <SectionTitle>Export</SectionTitle>
      <Card>
        <PrimaryButton label="Export JSON (full)" onPress={export_json} disabled={busy} />
        <SecondaryButton label="Export CSV: sessions" onPress={() => export_csv('sessions')} />
        <SecondaryButton label="Export CSV: attempts" onPress={() => export_csv('attempts')} />
        <SecondaryButton label="Export CSV: climbs" onPress={() => export_csv('climbs')} />
      </Card>

      <SectionTitle>Backup and restore</SectionTitle>
      <Card>
        <PrimaryButton label="Back up now" onPress={backup_now} disabled={busy} />
        <SecondaryButton label="Restore from a local backup" tone="danger" onPress={restore_from_backup} />
        <SecondaryButton label="Import a file" onPress={import_file} />
        <Text style={{ color: colors.textMuted }}>
          {lastBackupAt === null ? 'No automatic backup yet.' : `Last backup: ${lastBackupAt.slice(0, 16).replace('T', ' ')}`}
        </Text>
      </Card>

      {container.buildVariant === 'release' ? null : (
        <>
          <SectionTitle>Developer</SectionTitle>
          <Card>
            <SecondaryButton label="Feature flags" onPress={() => router.push('/dev/flags')} />
          </Card>
        </>
      )}

      <SectionTitle>About</SectionTitle>
      <Card>
        <Text style={{ color: colors.textMuted }}>Version {app_version()}</Text>
        <Text style={{ color: colors.textMuted }}>Schema version {container.schemaVersion}</Text>
      </Card>

      {note === null ? null : <Text style={{ color: colors.warning }}>{note}</Text>}
    </Screen>
  );
}

// The executor port has no file path concept; the device adapter does.
function db_path_of(executor: unknown): string | undefined {
  const candidate = executor as { dbPath?: () => string };
  return typeof candidate.dbPath === 'function' ? candidate.dbPath() : undefined;
}
