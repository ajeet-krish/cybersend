import { Stack } from 'expo-router';

import { Providers } from '@/src/app/providers';

export default function RootLayout() {
  return (
    <Providers>
      <Stack>
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
        <Stack.Screen name="session/[id]" options={{ title: 'Session' }} />
        <Stack.Screen name="climb/[id]" options={{ title: 'Climb' }} />
        <Stack.Screen name="gyms" options={{ title: 'Gyms' }} />
        <Stack.Screen name="grades" options={{ title: 'Grade schemes' }} />
        <Stack.Screen name="dev/flags" options={{ title: 'Feature flags' }} />
      </Stack>
    </Providers>
  );
}
