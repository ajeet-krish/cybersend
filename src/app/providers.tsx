// Root providers: initialize the DI container once, surface a graceful error screen when the
// native database module is missing (Expo Go), run the app background backup trigger (at most
// hourly), and expose repositories plus flags through context. Feature stores consume this via
// useAppRepositories.

import { createContext, useContext, useEffect, useMemo, useRef, useState, type PropsWithChildren } from 'react';
import { ActivityIndicator, AppState, StyleSheet, Text, View } from 'react-native';

import { init_app_container, type AppContainer } from './di';
import type { FlagValues } from './flags';
import type { Repositories } from '../data/repositories';
import { maybe_write_automatic_backup } from '../features/backup/backup_service';
import { createLogbookStore, type LogbookStore } from '../features/sessions/logbook_store';
import { useTheme } from '../ui/theme';

interface AppContextValue {
  container: AppContainer;
  logbook: LogbookStore;
  setFlags: (flags: FlagValues) => void;
}

const AppContext = createContext<AppContextValue | null>(null);

export function useAppContext(): AppContextValue {
  const value = useContext(AppContext);
  if (value === null) {
    throw new Error('useAppContext must be used inside <Providers>');
  }
  return value;
}

export function useAppRepositories(): Repositories {
  return useAppContext().container.repos;
}

export function useAppFlags(): FlagValues {
  return useAppContext().container.flags;
}

export function useLogbook(): LogbookStore {
  return useAppContext().logbook;
}

type InitState =
  | { status: 'loading' }
  | { status: 'ready'; container: AppContainer }
  | { status: 'error'; message: string };

export function Providers({ children }: PropsWithChildren) {
  const [state, setState] = useState<InitState>({ status: 'loading' });
  const backup_running = useRef(false);

  useEffect(() => {
    let mounted = true;
    init_app_container()
      .then((container) => {
        if (mounted) {
          setState({ status: 'ready', container });
        }
      })
      .catch((error: unknown) => {
        if (mounted) {
          setState({ status: 'error', message: error instanceof Error ? error.message : String(error) });
        }
      });
    return () => {
      mounted = false;
    };
  }, []);

  useEffect(() => {
    if (state.status !== 'ready') {
      return undefined;
    }
    const subscription = AppState.addEventListener('change', (next_state) => {
      if (next_state !== 'background' || backup_running.current) {
        return;
      }
      backup_running.current = true;
      maybe_write_automatic_backup(state.container.repos, 'app_background').finally(() => {
        backup_running.current = false;
      });
    });
    return () => subscription.remove();
  }, [state]);

  const value = useMemo<AppContextValue | null>(() => {
    if (state.status !== 'ready') {
      return null;
    }
    return {
      container: state.container,
      logbook: createLogbookStore(state.container.repos),
      setFlags: (flags: FlagValues) => setState({ status: 'ready', container: { ...state.container, flags } }),
    };
  }, [state]);

  if (state.status === 'loading') {
    return <BootScreen message="Opening your logbook" />;
  }
  if (state.status === 'error') {
    return <ErrorScreen message={state.message} />;
  }
  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}

function BootScreen({ message }: { message: string }) {
  const { colors } = useTheme();
  return (
    <View style={[styles.center, { backgroundColor: colors.background }]}>
      <ActivityIndicator size="large" color={colors.primary} />
      <Text style={[styles.message, { color: colors.textMuted }]}>{message}</Text>
    </View>
  );
}

function ErrorScreen({ message }: { message: string }) {
  const { colors } = useTheme();
  return (
    <View style={[styles.center, { backgroundColor: colors.background }]}>
      <Text style={[styles.title, { color: colors.text }]}>Database unavailable</Text>
      <Text style={[styles.message, { color: colors.textMuted }]}>{message}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  center: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
  },
  title: {
    fontSize: 20,
    fontWeight: '600',
    marginBottom: 8,
  },
  message: {
    fontSize: 14,
    textAlign: 'center',
    marginTop: 12,
  },
});
