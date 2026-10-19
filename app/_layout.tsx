import { Stack } from 'expo-router';

import { Providers } from '@/src/app/providers';

export default function RootLayout() {
  return (
    <Providers>
      <Stack />
    </Providers>
  );
}
