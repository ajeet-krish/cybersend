import SwiftUI

// Stats tab (M3 Task 5, US-23): the typed NavigationStack for the stats dashboard over
// StatsView, which reads the Features StatsStore (fall heatmap on the wall photo, rates
// by grade, volume over time). The frozen TypeScript spec app/(tabs)/stats.tsx had this
// as the fourth tab; the native port lands it with M3 per the user decision folding
// US-23 into M3.

struct StatsTabView: View {
    var body: some View {
        NavigationStack {
            StatsView()
                .navigationTitle("Stats")
        }
    }
}
