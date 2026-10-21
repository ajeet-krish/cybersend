import SwiftUI

// Shared page background for the screens that use a List instead of Screen (Settings,
// Sessions history, Feature flags). The system grouped background would ignore the
// cyberpunk surface tokens, so it is hidden and the themed page background shows through,
// keeping List based screens visually identical to the ScrollView based ones.

extension View {
    func themedPageBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.screenBackground.ignoresSafeArea())
    }
}
