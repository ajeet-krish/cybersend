import Combine
import CyberSendData
import CyberSendDomain
import Foundation

// Settings store (M2): the settings tab preferences (default gym, default grade scheme,
// appearance, photo retention) plus the resolved feature flag values. Every setter writes
// through the repositories and refreshes immediately, so a fresh store reads back exactly
// what the user chose. Settings rows are free form JSON, which keeps the keys export safe
// (docs/decisions.md, storage root note).

@MainActor
public final class SettingsStore: ObservableObject {
    /// The build variant that supplies compile time flag defaults (port of the placeholder
    /// SettingsTabStore so the flags screen can label the current build).
    public let variant: BuildVariant

    /// The persisted default gym (settings key settingsKeyDefaultGymID); nil when unset,
    /// in which case LogbookStore falls back to the first active gym.
    @Published public private(set) var defaultGymId: String?
    /// The persisted default grade scheme (settings key settingsKeyDefaultGradeSystem);
    /// nil when unset. Display falls back to the built-in defaultGradeSystemID.
    @Published public private(set) var defaultGradeSystemId: String?
    /// Appearance override (settings key settingsKeyAppearance). Dark is the documented
    /// default for this app (cyberpunk dark first); the override only changes it when the
    /// user picks something else, and an unset key always resolves to dark.
    @Published public private(set) var appearance: AppearancePreference = .dark
    /// Photo retention preference (settings key settingsKeyPhotoRetention); the default
    /// keeps captured originals (enforcement starts with M3).
    @Published public private(set) var photoRetention: PhotoRetentionPreference = .keepOriginals
    /// Compile time defaults for the variant merged with settings overrides (the
    /// flags.override key), same resolution as resolvedFlags.
    @Published public private(set) var flagValues: FlagValues
    /// True after the pose pipeline was turned off by the crash guard at launch (US-40.3). The
    /// Settings screen keeps its Experimental section visible while this is set, so the user can
    /// turn the feature back on without the developer flags screen.
    @Published public private(set) var poseWasAutoDisabled = false

    private let repos: Repositories
    private let poseGuard: PoseCrashGuard

    public init(
        repos: Repositories,
        variant: BuildVariant = .development,
        poseGuard: PoseCrashGuard = PoseCrashGuard()
    ) {
        self.repos = repos
        self.variant = variant
        self.poseGuard = poseGuard
        self.flagValues = defaultFlags(for: variant)
        refresh()
    }

    /// Alias of flagValues so views ported from the placeholder SettingsTabStore keep
    /// reading `store.flags`.
    public var flags: FlagValues { flagValues }

    /// Reloads every preference from the settings table. Missing keys fall back to the
    /// documented defaults and corrupt JSON falls back like the TypeScript tolerant reads
    /// instead of failing the screen.
    public func refresh() {
        defaultGymId = try? repos.settings.getJSON(key: settingsKeyDefaultGymID, as: String.self)
        defaultGradeSystemId = try? repos.settings.getJSON(key: settingsKeyDefaultGradeSystem, as: String.self)
        if let raw = try? repos.settings.getJSON(key: settingsKeyAppearance, as: String.self),
           let preference = AppearancePreference(rawValue: raw) {
            appearance = preference
        } else {
            appearance = .dark
        }
        if let raw = try? repos.settings.getJSON(key: settingsKeyPhotoRetention, as: String.self),
           let preference = PhotoRetentionPreference(rawValue: raw) {
            photoRetention = preference
        } else {
            photoRetention = .keepOriginals
        }
        flagValues = (try? resolvedFlags(for: variant, settings: repos.settings))
            ?? defaultFlags(for: variant)
        poseWasAutoDisabled = poseGuard.wasAutoDisabled
    }

    /// Persists the default gym immediately; nil removes the key (unset).
    public func setDefaultGym(_ gymId: String?) throws {
        if let gymId {
            try repos.settings.setJSON(key: settingsKeyDefaultGymID, value: gymId)
        } else {
            try repos.settings.remove(key: settingsKeyDefaultGymID)
        }
        refresh()
    }

    /// Persists the default grade scheme immediately; nil removes the key (unset). Known
    /// schemes are validated by the grade repository (throws grade_system_not_found).
    public func setDefaultGradeSystem(_ systemId: String?) throws {
        if let systemId {
            try repos.grades.setDefaultSystem(id: systemId)
        } else {
            try repos.settings.remove(key: settingsKeyDefaultGradeSystem)
        }
        refresh()
    }

    /// Persists the appearance override immediately (US-25.2); nil-preference handling is
    /// not needed because .system is a stored value, not an absent key.
    public func setAppearance(_ preference: AppearancePreference) throws {
        try repos.settings.setJSON(key: settingsKeyAppearance, value: preference.rawValue)
        refresh()
    }

    /// Persists the photo retention preference immediately (US-25, enforced from M3).
    public func setPhotoRetention(_ retention: PhotoRetentionPreference) throws {
        try repos.settings.setJSON(key: settingsKeyPhotoRetention, value: retention.rawValue)
        refresh()
    }

    /// Writes one flag override over the existing flags.override JSON (unknown keys and
    /// other flags survive) and refreshes, so the resolved value merges the override over
    /// the build variant defaults exactly like resolvedFlags.
    public func setFlag(_ flag: FeatureFlag, enabled: Bool) throws {
        var overrides: [String: Bool] = [:]
        if let raw = try repos.settings.get(key: settingsKeyFlagOverrides),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            overrides = decoded
        }
        overrides[flag.rawValue] = enabled
        try repos.settings.setJSON(key: settingsKeyFlagOverrides, value: overrides)
        // Turning the pose feature back on dismisses the crash guard's notice.
        if flag == .aiPoseAnalysis, enabled {
            poseGuard.clearAutoDisabled()
        }
        refresh()
    }
}
