import Foundation

// Typed navigation routes per tab (docs/decisions.md, 2026-10-20 M2: NavigationStack plus
// TabView with typed route enums per tab; docs/architecture.md M2 navigation). Each enum
// mirrors a frozen TypeScript spec route (app/gyms.tsx, app/grades.tsx, app/climb/[id].tsx,
// app/session/[id].tsx, app/dev/flags.tsx). The M2 Task 3 shell registers the destinations;
// Task 4 and later fill in the screens.

/// The tab identifiers.
enum AppTab: Hashable, CaseIterable {
    case logbook
    case sessions
    case settings
}

/// Routes under the Logbook tab.
enum LogbookRoute: Hashable {
    case gyms
    case grades
    case gymDetail(gymId: String)
    case climbDetail(climbId: String)
}

/// Routes under the Sessions tab. The session screen is also reachable from the Logbook
/// tab (quick log climb rows), which is why both stacks register this route.
enum SessionsRoute: Hashable {
    /// The session screen. climbId preselects the quick log climb (Logbook climb rows).
    case sessionDetail(sessionId: String, climbId: String?)
}

/// Routes under the Settings tab.
enum SettingsRoute: Hashable {
    case appearance
    case featureFlags
    case backups
    case about
}
