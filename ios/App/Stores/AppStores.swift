import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import Foundation

// Placeholder stores for the M2 shell (M2 Task 3). These are deliberately small, read only
// stand-ins wired through repositories so the three tabs render real data. Task 4 replaces
// them with the Features logbook stores (docs/decisions.md, 2026-10-20 M2: per feature
// LogbookStore, SessionDetailStore, GymsStore, GradeSchemesStore, SettingsStore). Replacement
// stays localized: AppEnvironment builds AppStores here, and views consume only these
// properties through @EnvironmentObject, so swapping the concrete types touches
// AppStores.swift and each view's property type, nothing else.

/// The store bundle injected into the view tree.
@MainActor
struct AppStores {
    let logbook: LogbookTabStore
    let sessions: SessionsTabStore
    let settings: SettingsTabStore

    init(repos: Repositories, variant: BuildVariant, flags: FlagValues) {
        self.logbook = LogbookTabStore(repos: repos)
        self.sessions = SessionsTabStore(repos: repos)
        self.settings = SettingsTabStore(repos: repos, variant: variant, flags: flags)
    }
}

/// Logbook tab data (placeholder): gyms, the open session, and recent history rows.
@MainActor
final class LogbookTabStore: ObservableObject {
    @Published private(set) var gyms: [Gym] = []
    @Published private(set) var openSession: Session?
    @Published private(set) var recentSessions: [SessionSummary] = []
    @Published private(set) var lastErrorMessage: String?

    private let repos: Repositories

    init(repos: Repositories) {
        self.repos = repos
    }

    func refresh() {
        do {
            gyms = try repos.gyms.list(includeArchived: false)
            openSession = try repos.sessions.getOpen()
            recentSessions = try repos.sessions.list(limit: 5)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}

/// Sessions tab data (placeholder): reverse chronological history rows joined with the gym
/// name for display (US-22).
@MainActor
final class SessionsTabStore: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let attemptCount: Int
        let isOpen: Bool
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var lastErrorMessage: String?

    private let repos: Repositories

    init(repos: Repositories) {
        self.repos = repos
    }

    func refresh() {
        do {
            let summaries = try repos.sessions.list(limit: 100)
            var gymNames: [String: String] = [:]
            for gym in try repos.gyms.list(includeArchived: true) {
                gymNames[gym.id] = gym.name
            }
            rows = summaries.map { summary in
                Row(
                    id: summary.session.id,
                    title: gymNames[summary.session.gymId] ?? "Gym",
                    subtitle: Self.displayDate(from: summary.session.startedAt),
                    attemptCount: summary.attemptCount,
                    isOpen: summary.session.endedAt == nil
                )
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Formats the stored ISO 8601 UTC timestamp for display in the local time zone.
    private static func displayDate(from isoText: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoText) else { return isoText }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }
}

/// Settings tab data (placeholder): appearance preference persisted immediately (US-24,
/// US-25.2) and resolved feature flag values. Task 4 moves this into the Features
/// SettingsStore; the appearance settings key stays app side until the Domain layer
/// adopts it (settings rows are free form and export safe).
@MainActor
final class SettingsTabStore: ObservableObject {
    @Published private(set) var appearance: AppearancePreference
    @Published private(set) var flags: FlagValues
    let variant: BuildVariant

    private let repos: Repositories

    init(repos: Repositories, variant: BuildVariant, flags: FlagValues) {
        self.repos = repos
        self.variant = variant
        self.flags = flags
        if let raw = try? repos.settings.get(key: settingsKeyAppearanceMode),
           let preference = AppearancePreference(rawValue: raw) {
            self.appearance = preference
        } else {
            self.appearance = .system
        }
    }

    /// Persists the appearance override immediately (US-25.2).
    func setAppearance(_ preference: AppearancePreference) {
        guard preference != appearance else { return }
        appearance = preference
        let valueJson = "\"\(preference.rawValue)\""
        try? repos.settings.set(key: settingsKeyAppearanceMode, valueJson: valueJson)
    }
}
