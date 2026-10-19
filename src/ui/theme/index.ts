// Color tokens. Dark mode support lands in Phase 2 (US-24); both palettes exist now so screens
// theme from day one. Use useTheme() in components, never hard code colors.

import { useColorScheme } from 'react-native';

export interface ThemeColors {
  background: string;
  surface: string;
  surfaceRaised: string;
  border: string;
  text: string;
  textMuted: string;
  primary: string;
  onPrimary: string;
  danger: string;
  success: string;
  warning: string;
}

export const light_colors: ThemeColors = {
  background: '#f6f7f9',
  surface: '#ffffff',
  surfaceRaised: '#eef0f4',
  border: '#d8dce3',
  text: '#14181f',
  textMuted: '#5c6675',
  primary: '#1f6feb',
  onPrimary: '#ffffff',
  danger: '#c22c2c',
  success: '#1c7a3d',
  warning: '#9a6700',
};

export const dark_colors: ThemeColors = {
  background: '#0f1319',
  surface: '#171c24',
  surfaceRaised: '#212836',
  border: '#2c3442',
  text: '#e8ebf0',
  textMuted: '#98a2b3',
  primary: '#4c8dff',
  onPrimary: '#08101f',
  danger: '#ff6b6b',
  success: '#57d38c',
  warning: '#e3b341',
};

export interface Theme {
  colors: ThemeColors;
  spacing: { sm: number; md: number; lg: number };
}

export function useTheme(): Theme {
  const scheme = useColorScheme();
  return {
    colors: scheme === 'dark' ? dark_colors : light_colors,
    spacing: { sm: 8, md: 12, lg: 16 },
  };
}
