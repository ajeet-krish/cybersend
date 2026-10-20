import SwiftUI

// Settings tab (M2 Task 5): the typed NavigationStack over the SettingsView screen. The
// screen owns the defaults, appearance, retention, export, and backup surfaces plus the
// destructive restore confirmation (docs/architecture.md M2 app layer); the feature
// flags destination is the only pushed screen on non release builds.

struct SettingsTabView: View {
    let services: AppServices?

    var body: some View {
        NavigationStack {
            if let services {
                SettingsView(services: services)
            } else {
                // Defensive: only previews reach this; the root always injects services.
                List {
                    Section("Backup and restore") {
                        Text("Storage is unavailable on this launch.")
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier("settings.services.unavailable")
                    }
                }
                .accessibilityIdentifier("settings.screen")
                .navigationTitle("Settings")
            }
        }
    }
}
