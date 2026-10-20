import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Feature flags (port of src/app/__tests__/flags.test.ts): per variant defaults, merge
// semantics, variant reading, and the settings table override wiring.

@Suite("Feature flag defaults")
struct FeatureFlagDefaultTests {
    @Test("AI flags and board_import are off in every variant")
    func aiFlagsOffEverywhere() {
        for variant in BuildVariant.allCases {
            let flags = defaultFlags(for: variant)
            #expect(flags.aiHoldDetection == false)
            #expect(flags.aiPoseAnalysis == false)
            #expect(flags.boardImport == false)
        }
    }

    @Test("boulder_vision is on outside release only")
    func boulderVisionOutsideRelease() {
        #expect(defaultFlags(for: .development).boulderVision == true)
        #expect(defaultFlags(for: .internalBuild).boulderVision == true)
        #expect(defaultFlags(for: .release).boulderVision == false)
    }

    @Test("video capture and grade normalization follow the variant defaults")
    func otherDefaultsMatchTypeScript() {
        #expect(defaultFlags(for: .development).videoCapture == true)
        #expect(defaultFlags(for: .internalBuild).videoCapture == true)
        #expect(defaultFlags(for: .release).videoCapture == false)
        #expect(defaultFlags(for: .release).gradeNormalization == false)
    }
}

@Suite("mergeFlags")
struct FeatureFlagMergeTests {
    @Test("overrides win over defaults without mutating them")
    func overridesWin() {
        let defaults = defaultFlags(for: .release)
        let merged = mergeFlags(defaults, overrides: [.aiHoldDetection: true])
        #expect(merged.aiHoldDetection == true)
        #expect(merged.boulderVision == false)
        #expect(defaults.aiHoldDetection == false, "FlagValues is a value type; defaults stay intact")
    }

    @Test("settings JSON overrides merge and ignore unknown keys")
    func settingsJSONMerges() {
        let defaults = defaultFlags(for: .release)
        let merged = mergeFlags(defaults, overridesJSON: "{\"ai_hold_detection\": true, \"bogus_flag\": true}")
        #expect(merged.aiHoldDetection == true)
        #expect(merged.boulderVision == false)

        // Malformed JSON leaves the defaults untouched.
        #expect(mergeFlags(defaults, overridesJSON: "not json") == defaults)
        #expect(mergeFlags(defaults, overridesJSON: nil) == defaults)
    }
}

@Suite("readBuildVariant")
struct ReadBuildVariantTests {
    @Test("reads a known variant")
    func readsKnownVariant() {
        #expect(readBuildVariant(rawValue: "internal") == .internalBuild)
        #expect(readBuildVariant(rawValue: "release") == .release)
        #expect(readBuildVariant(rawValue: "development") == .development)
    }

    @Test("missing or unknown values fall back to development")
    func fallsBackToDevelopment() {
        #expect(readBuildVariant(rawValue: nil) == .development)
        #expect(readBuildVariant(rawValue: "") == .development)
        #expect(readBuildVariant(rawValue: "bogus") == .development)
    }
}

@Suite("Flag settings wiring")
struct FlagSettingsWiringTests {
    @Test("resolvedFlags applies settings overrides over variant defaults")
    func resolvedFlagsUsesSettings() throws {
        let test = try makeTestDatabase()
        try test.repos.settings.setJSON(key: settingsKeyFlagOverrides, value: ["ai_hold_detection": true])

        let release = try resolvedFlags(for: .release, settings: test.repos.settings)
        #expect(release.aiHoldDetection == true)
        #expect(release.boulderVision == false)

        let development = try resolvedFlags(for: .development, settings: test.repos.settings)
        #expect(development.aiHoldDetection == true)
        #expect(development.boulderVision == true)
    }

    @Test("resolvedFlags falls back to defaults without an override and survives corrupt JSON")
    func resolvedFlagsFallsBack() throws {
        let test = try makeTestDatabase()
        let plain = try resolvedFlags(for: .development, settings: test.repos.settings)
        #expect(plain == defaultFlags(for: .development))

        try test.repos.settings.set(key: settingsKeyFlagOverrides, valueJson: "{corrupt")
        let corrupt = try resolvedFlags(for: .development, settings: test.repos.settings)
        #expect(corrupt == defaultFlags(for: .development))
    }

    @Test("override JSON round trips through the settings repository in the TS shape")
    func overrideJSONShape() throws {
        let test = try makeTestDatabase()
        try test.repos.settings.setJSON(
            key: settingsKeyFlagOverrides,
            value: ["boulder_vision": false, "video_capture": true]
        )
        let raw = try test.repos.settings.get(key: settingsKeyFlagOverrides)
        #expect(raw?.contains("\"boulder_vision\":false") == true)

        let merged = mergeFlags(defaultFlags(for: .development), overridesJSON: raw)
        #expect(merged.boulderVision == false)
        #expect(merged.videoCapture == true)
    }
}
