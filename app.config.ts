import type { ConfigContext, ExpoConfig } from 'expo/config';

import type { BuildVariant } from './src/app/flags';

// The build variant is chosen at prebuild time with BUILD_VARIANT and read at runtime by src/app/flags.ts.
const allowed_variants: readonly BuildVariant[] = ['development', 'internal', 'release'];

function resolve_build_variant(): BuildVariant {
  const raw = process.env.BUILD_VARIANT ?? 'development';
  return allowed_variants.find((variant) => variant === raw) ?? 'development';
}

export default ({ config }: ConfigContext): ExpoConfig => ({
  ...config,
  name: 'CyberSend',
  slug: 'cybersend',
  version: '0.1.0',
  orientation: 'portrait',
  scheme: 'cybersend',
  icon: './assets/icon.png',
  userInterfaceStyle: 'automatic',
  plugins: ['expo-router'],
  ios: {
    bundleIdentifier: 'com.cybersend.app',
    deploymentTarget: '16.0',
    supportsTablet: false,
    icon: './assets/icon.png',
  },
  extra: {
    buildVariant: resolve_build_variant(),
  },
});
