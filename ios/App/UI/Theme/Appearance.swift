import CyberSendDomain
import SwiftUI

// Presentation helpers for the Domain appearance preference (settings key
// settingsKeyAppearance, "ui.appearance"; docs/decisions.md 2026-10-20 M2). The Domain
// enum is the single source of truth; the 2026-10-20 review removed the app local
// duplicate enum and its "appearance.mode" key. Persistence goes through
// SettingsStore.setAppearance, which reads and writes ui.appearance (US-24, US-25.2).

extension AppearancePreference {
    /// The preferredColorScheme override; nil means follow the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The settings picker title.
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
