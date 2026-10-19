// Shared UI primitives. Pixels exist only in the UI layer (AGENTS.md).

import type { PropsWithChildren, ReactNode } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, TextInput, View, type TextInputProps } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { useTheme } from '../theme';

export function Screen({ children, scroll = true }: PropsWithChildren<{ children: ReactNode; scroll?: boolean }>) {
  const { colors } = useTheme();
  const body = scroll ? (
    <ScrollView contentContainerStyle={styles.scroll_content}>{children}</ScrollView>
  ) : (
    <View style={styles.scroll_content}>{children}</View>
  );
  return <SafeAreaView style={[styles.screen, { backgroundColor: colors.background }]}>{body}</SafeAreaView>;
}

export function Card({ children }: PropsWithChildren) {
  const { colors, spacing } = useTheme();
  return <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border, padding: spacing.lg }]}>{children}</View>;
}

export function SectionTitle({ children }: PropsWithChildren) {
  const { colors } = useTheme();
  return <Text style={[styles.section_title, { color: colors.textMuted }]}>{children}</Text>;
}

export function Row({ children }: PropsWithChildren) {
  return <View style={styles.row}>{children}</View>;
}

export function PrimaryButton({
  label,
  onPress,
  disabled = false,
}: {
  label: string;
  onPress: () => void;
  disabled?: boolean;
}) {
  const { colors, spacing } = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      disabled={disabled}
      style={({ pressed }) => [
        styles.button,
        { backgroundColor: colors.primary, opacity: disabled ? 0.5 : pressed ? 0.8 : 1, padding: spacing.md },
      ]}
    >
      <Text style={[styles.button_label, { color: colors.onPrimary }]}>{label}</Text>
    </Pressable>
  );
}

export function SecondaryButton({
  label,
  onPress,
  tone = 'default',
}: {
  label: string;
  onPress: () => void;
  tone?: 'default' | 'danger';
}) {
  const { colors, spacing } = useTheme();
  const text_color = tone === 'danger' ? colors.danger : colors.text;
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        { backgroundColor: colors.surface, borderColor: colors.border, borderWidth: 1, opacity: pressed ? 0.7 : 1, padding: spacing.md },
      ]}
    >
      <Text style={[styles.button_label, { color: text_color }]}>{label}</Text>
    </Pressable>
  );
}

export function Chip({
  label,
  selected = false,
  onPress,
}: {
  label: string;
  selected?: boolean;
  onPress?: () => void;
}) {
  const { colors, spacing } = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={({ pressed }) => [
        styles.chip,
        {
          backgroundColor: selected ? colors.primary : colors.surface,
          borderColor: selected ? colors.primary : colors.border,
          opacity: pressed ? 0.8 : 1,
          margin: spacing.sm / 2,
          paddingVertical: spacing.sm / 1.5,
          paddingHorizontal: spacing.sm,
        },
      ]}
    >
      <Text style={[styles.chip_label, { color: selected ? colors.onPrimary : colors.text }]}>{label}</Text>
    </Pressable>
  );
}

export function Field({
  label,
  ...input_props
}: { label: string } & TextInputProps) {
  const { colors, spacing } = useTheme();
  return (
    <View style={{ marginBottom: spacing.md }}>
      <Text style={[styles.field_label, { color: colors.textMuted }]}>{label}</Text>
      <TextInput
        {...input_props}
        style={[
          styles.input,
          { color: colors.text, backgroundColor: colors.surface, borderColor: colors.border, padding: spacing.sm },
        ]}
      />
    </View>
  );
}

export function EmptyState({ title, hint }: { title: string; hint?: string }) {
  const { colors } = useTheme();
  return (
    <View style={styles.empty}>
      <Text style={[styles.empty_title, { color: colors.text }]}>{title}</Text>
      {hint === undefined ? null : <Text style={[styles.empty_hint, { color: colors.textMuted }]}>{hint}</Text>}
    </View>
  );
}

const styles = StyleSheet.create({
  screen: {
    flex: 1,
  },
  scroll_content: {
    padding: 16,
    gap: 12,
  },
  card: {
    borderRadius: 12,
    borderWidth: 1,
    gap: 8,
  },
  section_title: {
    fontSize: 12,
    fontWeight: '600',
    textTransform: 'uppercase',
    letterSpacing: 0.6,
    marginTop: 8,
  },
  row: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
  },
  button: {
    borderRadius: 10,
    borderWidth: 1,
    borderColor: 'transparent',
    alignItems: 'center',
  },
  button_label: {
    fontSize: 15,
    fontWeight: '600',
  },
  chip: {
    borderRadius: 999,
    borderWidth: 1,
  },
  chip_label: {
    fontSize: 14,
    fontWeight: '500',
  },
  field_label: {
    fontSize: 13,
    marginBottom: 4,
  },
  input: {
    borderRadius: 10,
    borderWidth: 1,
    fontSize: 15,
  },
  empty: {
    alignItems: 'center',
    padding: 24,
    gap: 6,
  },
  empty_title: {
    fontSize: 16,
    fontWeight: '600',
  },
  empty_hint: {
    fontSize: 13,
    textAlign: 'center',
  },
});
