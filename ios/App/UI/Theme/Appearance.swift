import SwiftUI

// Appearance preference (docs/decisions.md, 2026-10-20 M2: appearance preference system,
// light, dark is a new settings key, export safe because settings rows are free form).
// US-24 requires system follow plus manual override, persisted across launches; the
// SettingsTabStore persists the raw value immediately on change.

/// The user's appearance override.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// The preferredColorScheme override; nil means follow the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Settings table key for the appearance override. Lives app side for the M2 shell; the
/// Domain layer can adopt it when the settings screen grows (rows are free form, so old
/// exports stay compatible).
let settingsKeyAppearanceMode = "appearance.mode"
