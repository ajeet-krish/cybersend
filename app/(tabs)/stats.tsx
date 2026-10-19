// Stats tab placeholder. The dashboard with fall heatmap arrives in Phase 2 (US-23).

import { EmptyState, Screen, SectionTitle } from '@/src/ui/components';

export default function StatsScreen() {
  return (
    <Screen>
      <SectionTitle>Stats</SectionTitle>
      <EmptyState
        title="Stats arrive in Phase 2"
        hint="Flash and send rates by grade, volume over time, and the fall heatmap on your wall photos."
      />
    </Screen>
  );
}
