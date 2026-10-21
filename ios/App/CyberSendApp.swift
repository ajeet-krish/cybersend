import CyberSendFeatures
import Foundation
import SwiftUI

// App entry point (docs/architecture.md M2): bootstrap runs once at launch, and the
// scenePhase background hook calls the M1 scheduled backup entry point (hourly throttle,
// keep 10; US-15). The backup runs off the main actor with Sendable values only.

@main
struct CyberSendApp: App {
    @StateObject private var launch = LaunchModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(launch: launch)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                launch.performScheduledBackup()
            }
        }
    }
}

/// Owns the launch state and the composition root for the app's lifetime. Bootstrap is
/// synchronous (migrations are small and run once; the 2.5 s cold start budget is measured
/// in dogfood, docs/requirements.md section 6).
@MainActor
final class LaunchModel: ObservableObject {
    @Published private(set) var state: LaunchState = .loading
    @Published private(set) var environment: AppEnvironment?

    private var bootstrap: AppBootstrap
    private var mediaSweepRan = false

    init(bootstrap: AppBootstrap = .live()) {
        self.bootstrap = bootstrap
        let result = bootstrap.run()
        self.state = result.state
        self.environment = result.environment
    }

    /// Re runs the bootstrap after a migration failure (the Try again button).
    func retry() {
        let result = bootstrap.run()
        state = result.state
        environment = result.environment
    }

    /// The M3 media sweep (docs/architecture.md launch): reconciles photo rows and files
    /// off the main actor, async after the first frame so the 2.5 s cold start budget is
    /// untouched. Runs once per launch, best effort; the next launch reconciles again.
    func performLaunchMediaSweep() {
        guard !mediaSweepRan, let environment else { return }
        mediaSweepRan = true
        let runSweep = environment.media.runSweep
        Task.detached(priority: .utility) {
            _ = try? runSweep()
        }
    }

    /// The scenePhase background hook: throttled automatic backup, best effort. Failures
    /// must never crash the app; the persistent warning badge path is a later milestone.
    func performScheduledBackup() {
        guard let environment else { return }
        let repos = environment.repos
        let root = environment.documentDirectory
        Task.detached(priority: .utility) {
            _ = try? runScheduledBackup(repos: repos, documentDirectory: root)
        }
    }
}
