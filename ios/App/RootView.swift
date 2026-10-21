import CyberSendFeatures
import SwiftUI

// Root of the view tree (docs/architecture.md M2 launch flow): ready builds the three tab
// NavigationStacks with the stores and services injected; newerDatabase and migrationFailed
// render the US-7 guidance screen; loading is a brief progress state while bootstrap runs.

struct RootView: View {
    @ObservedObject var launch: LaunchModel

    var body: some View {
        switch launch.state {
        case .loading:
            LaunchProgressView()
        case .ready:
            if let environment = launch.environment {
                MainTabView()
                    .environmentObject(environment.stores.logbook)
                    .environmentObject(environment.stores.gyms)
                    .environmentObject(environment.stores.grades)
                    .environmentObject(environment.stores.settings)
                    .environmentObject(environment.stores.history)
                    .environmentObject(environment.stores.climbThumbnails)
                    .environmentObject(environment.stores.stats)
                    .environment(
                        \.appServices,
                        AppServices(
                            repos: environment.repos,
                            documentDirectory: environment.documentDirectory,
                            backupProcedures: environment.backupProcedures,
                            media: environment.media
                        )
                    )
                    .task {
                        // M3 launch hook (docs/architecture.md): the media sweep runs
                        // async after the first frame, so the cold start budget is
                        // untouched. Best effort; failures never block the UI.
                        launch.performLaunchMediaSweep()
                    }
            } else {
                // Defensive: ready without an environment should be impossible.
                LaunchProgressView()
            }
        case .newerDatabase, .migrationFailed:
            MigrationFailureView(
                state: launch.state,
                onRetry: { launch.retry() },
                onRestore: {}
            )
        }
    }
}

/// The four tab shells (Logbook, Stats, Sessions, Settings per docs/architecture.md M3;
/// the frozen TypeScript spec app/(tabs)/_layout.tsx carried the Stats tab and US-23
/// lands it with M3). Appearance override applies at the root so every screen follows
/// US-24; SettingsStore persists it under settingsKeyAppearance ("ui.appearance").
struct MainTabView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.appServices) private var services

    var body: some View {
        TabView {
            LogbookTabView()
                .tabItem { Label("Logbook", systemImage: "list.bullet") }
                .tag(AppTab.logbook)
            StatsTabView()
                .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }
                .tag(AppTab.stats)
            SessionsTabView()
                .tabItem { Label("Sessions", systemImage: "calendar") }
                .tag(AppTab.sessions)
            SettingsTabView(services: services)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}

/// Full screen progress shown while the (synchronous) bootstrap runs and defensively if a
/// ready state ever lacks its environment.
struct LaunchProgressView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening logbook")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.screenBackground.ignoresSafeArea())
    }
}
