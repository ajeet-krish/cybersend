import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Pose crash guard (US-40.3): a marker around each run, a recovery at launch that reports the
// interrupted run, and a persisted notice that Settings uses to offer a way back on. The guard
// only reports; the launch path flips the flag.

private func isolatedDefaults() -> UserDefaults {
    let name = "PoseCrashGuardTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Pose crash guard")
struct PoseCrashGuardTests {
    @Test("a started run leaves a marker that clear removes")
    func markerLifecycle() throws {
        let guardStore = PoseCrashGuard(defaults: isolatedDefaults())
        #expect(guardStore.marker() == nil)

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        guardStore.begin(videoId: "video-1", at: startedAt)

        let marker = try #require(guardStore.marker())
        #expect(marker.videoId == "video-1")
        #expect(marker.startedAt == startedAt)

        guardStore.clear()
        #expect(guardStore.marker() == nil)
    }

    @Test("a launch with no marker does not auto disable")
    func noMarkerNoRecovery() throws {
        let guardStore = PoseCrashGuard(defaults: isolatedDefaults())
        #expect(guardStore.recoverIfNeeded() == .none)
        #expect(guardStore.wasAutoDisabled == false)
    }

    @Test("a marker at launch reports the interrupted run and persists the notice")
    func recoveryReportsAndPersists() throws {
        let guardStore = PoseCrashGuard(defaults: isolatedDefaults())
        guardStore.begin(videoId: "video-2")

        let recovery = guardStore.recoverIfNeeded()
        #expect(recovery.autoDisabled)
        #expect(recovery.videoId == "video-2")
        #expect(guardStore.marker() == nil, "the marker is consumed")
        #expect(guardStore.wasAutoDisabled, "the notice survives for Settings")

        // A second launch does not report again, but the notice stays until the user acts.
        #expect(guardStore.recoverIfNeeded() == .none)
        #expect(guardStore.wasAutoDisabled)
    }

    @Test("turning the feature back on clears the notice")
    func clearNotice() throws {
        let guardStore = PoseCrashGuard(defaults: isolatedDefaults())
        guardStore.begin(videoId: "video-3")
        _ = guardStore.recoverIfNeeded()
        #expect(guardStore.wasAutoDisabled)

        guardStore.clearAutoDisabled()
        #expect(guardStore.wasAutoDisabled == false)
    }

    @Test("a completed run leaves no marker for the next launch")
    func completedRunIsClean() throws {
        let guardStore = PoseCrashGuard(defaults: isolatedDefaults())
        guardStore.begin(videoId: "video-4")
        guardStore.clear()
        #expect(guardStore.recoverIfNeeded() == .none)
        #expect(guardStore.wasAutoDisabled == false)
    }
}

@Suite("Settings pose crash notice")
@MainActor
struct SettingsPoseCrashNoticeTests {
    @Test("the settings store exposes the notice and clears it on re-enable")
    func settingsNotice() throws {
        let test = try makeTestDatabase()
        let defaults = isolatedDefaults()
        let guardStore = PoseCrashGuard(defaults: defaults)
        guardStore.begin(videoId: "video-5")
        _ = guardStore.recoverIfNeeded()

        let store = SettingsStore(repos: test.repos, variant: .development, poseGuard: guardStore)
        #expect(store.poseWasAutoDisabled, "Settings keeps the section visible after an auto disable")

        try store.setFlag(.aiPoseAnalysis, enabled: true)
        #expect(store.flags[.aiPoseAnalysis])
        #expect(store.poseWasAutoDisabled == false, "re-enabling dismisses the notice")
    }
}
