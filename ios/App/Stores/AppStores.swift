import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import Foundation

// The store bundle injected into the view tree (docs/decisions.md, 2026-10-20 M2: per
// feature ObservableObject stores from Features). AppBootstrap builds this once at
// launch; views observe the stores through @EnvironmentObject and never call repositories
// themselves (repositories only, US-13). The one app side store is SessionsHistoryStore:
// the Features LogbookStore caps its history query at 500 rows for the logbook tab while
// the sessions tab owns the full 1000 session budget (docs/requirements.md US-22.4).

/// The store bundle injected into the view tree.
@MainActor
struct AppStores {
    /// Logbook tab: gyms, persisted default gym, open session, quick log climbs (US-8 to US-12).
    let logbook: LogbookStore
    /// Gym managers screen: create, rename, archive (US-8).
    let gyms: GymsStore
    /// Grade schemes screen: built-ins and custom schemes, default scheme (US-9).
    let grades: GradeSchemesStore
    /// Settings tab preferences and resolved flags (US-24, US-25).
    let settings: SettingsStore
    /// Sessions tab history rows (US-22.1).
    let history: SessionsHistoryStore

    init(repos: Repositories, variant: BuildVariant) {
        self.logbook = LogbookStore(repos: repos)
        self.gyms = GymsStore(repos: repos)
        self.grades = GradeSchemesStore(repos: repos)
        self.settings = SettingsStore(repos: repos, variant: variant)
        self.history = SessionsHistoryStore(repos: repos)
    }
}
