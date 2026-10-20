import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Settings store tests (M2): documented defaults, immediate persistence read back through
// a fresh store, and flag overrides merged over the build variant defaults.

@Suite("SettingsStore")
@MainActor
struct SettingsStoreTests {
    @Test("fresh stores fall back to the documented defaults")
    func defaultsWhenUnset() throws {
        let test = try makeTestDatabase()
        let store = SettingsStore(repos: test.repos, variant: .development)

        #expect(store.defaultGymId == nil)
        #expect(store.defaultGradeSystemId == nil)
        #expect(store.appearance == .system)
        #expect(store.photoRetention == .keepOriginals)
        #expect(store.variant == .development)
        #expect(store.flagValues == defaultFlags(for: .development))
        #expect(store.flags == store.flagValues)
    }

    @Test("settings writes persist immediately and read back through a fresh store")
    func writesPersistImmediately() throws {
        let test = try makeTestDatabase()
        let gym = try seedGym(test.repos)
        let grades = GradeSchemesStore(repos: test.repos)
        let custom = try grades.createCustomSystem(name: "Custom", labels: ["1", "2"])
        let store = SettingsStore(repos: test.repos, variant: .development)

        try store.setDefaultGym(gym.id)
        try store.setDefaultGradeSystem(custom.id)
        try store.setAppearance(.dark)
        try store.setPhotoRetention(.discardOriginals)

        let fresh = SettingsStore(repos: test.repos, variant: .release)
        #expect(fresh.defaultGymId == gym.id)
        #expect(fresh.defaultGradeSystemId == custom.id)
        #expect(fresh.appearance == .dark)
        #expect(fresh.photoRetention == .discardOriginals)
        #expect(fresh.variant == .release)

        // Clearing the default gym removes the key again.
        try store.setDefaultGym(nil)
        let cleared = SettingsStore(repos: test.repos, variant: .development)
        #expect(cleared.defaultGymId == nil)

        // Unknown grade schemes are rejected before anything is written.
        let error = #expect(throws: DomainValidationError.self) {
            try store.setDefaultGradeSystem("missing-system")
        }
        #expect(error?.code == "grade_system_not_found")
        #expect(store.defaultGradeSystemId == custom.id)
    }

    @Test("flag overrides merge over the build variant defaults")
    func flagOverrideMergeHonored() throws {
        let test = try makeTestDatabase()
        let store = SettingsStore(repos: test.repos, variant: .development)
        #expect(store.flagValues.aiHoldDetection == false)
        #expect(store.flagValues.videoCapture == true)

        try store.setFlag(.aiHoldDetection, enabled: true)

        #expect(store.flagValues.aiHoldDetection == true)
        #expect(store.flagValues.videoCapture == true)

        // A fresh store in the same variant merges the persisted override identically.
        let fresh = SettingsStore(repos: test.repos, variant: .development)
        #expect(fresh.flagValues.aiHoldDetection == true)
        #expect(fresh.flagValues.videoCapture == true)

        // The override wins in every variant; untouched flags keep their variant defaults.
        let release = SettingsStore(repos: test.repos, variant: .release)
        #expect(release.flagValues.aiHoldDetection == true)
        #expect(release.flagValues.videoCapture == false)
        #expect(release.flagValues.gradeNormalization == false)
    }

    @Test("flipping a default flag off writes an override that survives reload")
    func flagOverrideOffPersists() throws {
        let test = try makeTestDatabase()
        let store = SettingsStore(repos: test.repos, variant: .development)

        try store.setFlag(.videoCapture, enabled: false)

        #expect(store.flagValues.videoCapture == false)
        let fresh = SettingsStore(repos: test.repos, variant: .development)
        #expect(fresh.flagValues.videoCapture == false)
        #expect(fresh.flagValues.gradeNormalization == true)
        #expect(fresh.flagValues.boulderVision == true)
    }
}
