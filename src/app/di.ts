// DI container: opens the device database, runs migrations, builds the repository set, and merges
// runtime feature flag overrides from the settings table over the compile time defaults
// (docs/architecture.md feature flags).

import Constants from 'expo-constants';

import { open_device_database } from '../data/db/connection';
import type { SqlExecutor } from '../data/db/executor';
import { create_repositories, type Repositories } from '../data/repositories';
import { SETTINGS_KEY_FLAG_OVERRIDES } from '../domain/models/settings';
import { defaultFlags, mergeFlags, readBuildVariant, type BuildVariant, type FlagName, type FlagValues } from './flags';

export interface AppContainer {
  executor: SqlExecutor;
  repos: Repositories;
  flags: FlagValues;
  buildVariant: BuildVariant;
  schemaVersion: number;
}

export async function init_app_container(): Promise<AppContainer> {
  const { executor, migration } = await open_device_database();
  const repos = create_repositories(executor);
  const buildVariant = readBuildVariant(Constants.expoConfig?.extra);
  const overrides = (await repos.settings.getJson<Partial<FlagValues>>(SETTINGS_KEY_FLAG_OVERRIDES)) ?? {};
  const flags = mergeFlags(defaultFlags(buildVariant), overrides);
  return { executor, repos, flags, buildVariant, schemaVersion: migration.schemaVersion };
}

// Persists one runtime flag override and returns the merged flags for an immediate UI update.
export async function update_flag_override(
  repos: Repositories,
  name: FlagName,
  value: boolean,
  current: FlagValues,
): Promise<FlagValues> {
  const overrides = (await repos.settings.getJson<Partial<FlagValues>>(SETTINGS_KEY_FLAG_OVERRIDES)) ?? {};
  overrides[name] = value;
  await repos.settings.setJson(SETTINGS_KEY_FLAG_OVERRIDES, overrides);
  return mergeFlags(current, { [name]: value });
}
