import CyberSendFeatures
import SwiftUI

// Settings tab shell (M2 Task 3): appearance picker wired to preferredColorScheme
// (US-24), feature flag values on non release builds (docs/architecture.md M2 settings),
// and placeholder rows for the Task 5 settings surfaces (US-25).

struct SettingsTabView: View {
    @EnvironmentObject private var store: SettingsTabStore

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    Picker("Theme", selection: appearanceBinding) {
                        ForEach(AppearancePreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Features") {
#if !RELEASE
                    NavigationLink(value: SettingsRoute.featureFlags) {
                        Row(title: "Feature flags", detail: enabledFlagSummary)
                    }
#endif
                }

                Section("Data") {
                    NavigationLink(value: SettingsRoute.backups) {
                        Row(title: "Backups", systemImage: "externaldrive")
                    }
                    NavigationLink(value: SettingsRoute.appearance) {
                        Row(title: "Defaults", systemImage: "slider.horizontal.3")
                    }
                }

                Section("About") {
                    NavigationLink(value: SettingsRoute.about) {
                        Row(title: "About CyberSend", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .featureFlags:
                    FeatureFlagsPendingView(flags: store.flags, variant: store.variant)
                default:
                    RoutePendingView(routeDescription: route.pendingDescription)
                }
            }
        }
    }

    /// Immediate persistence on change (US-25.2).
    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { store.appearance },
            set: { store.setAppearance($0) }
        )
    }

    private var enabledFlagSummary: String {
        let enabled = FeatureFlag.allCases.filter { store.flags[$0] }.count
        return "\(enabled) of \(FeatureFlag.allCases.count) on"
    }
}

/// Read only flag list for non release builds (the full toggling dev screen lands with
/// the Features settings work; hard gating in release is compile time via #if above).
struct FeatureFlagsPendingView: View {
    let flags: FlagValues
    let variant: BuildVariant

    var body: some View {
        Screen {
            SectionTitle("Build variant")
            Card {
                Row(title: "Variant", detail: variant.rawValue)
            }

            SectionTitle("Flags")
            Card {
                ForEach(FeatureFlag.allCases, id: \.self) { flag in
                    Row(title: flag.rawValue, detail: flags[flag] ? "On" : "Off")
                }
            }

            ErrorNote("Toggles arrive with the M2 settings work. Overrides are stored in the settings table and merge over these build defaults.")
        }
        .navigationTitle("Feature flags")
    }
}

extension SettingsRoute {
    var pendingDescription: String {
        switch self {
        case .appearance: return "Default gym and grade scheme"
        case .featureFlags: return "Feature flag toggles"
        case .backups: return "Backup and restore"
        case .about: return "About and licensing"
        }
    }
}
