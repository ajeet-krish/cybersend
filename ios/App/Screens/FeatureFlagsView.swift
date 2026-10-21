import CyberSendFeatures
import SwiftUI

// Feature flags screen (M2 Task 5, port of app/dev/flags.tsx): build variant label plus
// one toggle per flag. Every toggle writes through SettingsStore.setFlag into the
// settings override row (key flags.override) and the resolved value refreshes
// immediately (docs/architecture.md feature flags). The row itself only renders on
// non release builds; release gating is compile time at the call site.

struct FeatureFlagsView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var actionError: String?

    var body: some View {
        List {
            if let actionError {
                ErrorNote(actionError)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("flags.error")
            }

            Section("Build variant") {
                Row(title: "Variant", detail: settings.variant.rawValue)
                    .accessibilityIdentifier("flags.variant")
            }

            Section("Flags") {
                ForEach(FeatureFlag.allCases, id: \.self) { flag in
                    Toggle(title(for: flag), isOn: binding(for: flag))
                        .accessibilityIdentifier("flags.toggle.\(flag.rawValue)")
                }
            }

            Section {
                Text("Overrides are stored in the settings table and merge over the build defaults. BoulderVision is hard gated in release builds.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("flags.help")
            }
        }
        .themedPageBackground()
        .accessibilityIdentifier("flags.screen")
        .navigationTitle("Feature flags")
        .onAppear {
            settings.refresh()
        }
    }

    private func binding(for flag: FeatureFlag) -> Binding<Bool> {
        Binding(
            get: { settings.flags[flag] },
            set: { setFlag(flag, enabled: $0) }
        )
    }

    private func setFlag(_ flag: FeatureFlag, enabled: Bool) {
        do {
            try settings.setFlag(flag, enabled: enabled)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// "Video capture" style title from the stored snake_case flag name.
    private func title(for flag: FeatureFlag) -> String {
        flag.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
