#if DEVELOPMENT
import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import Foundation

// Debug only launch argument seeding for the XCUITest smoke set (docs/architecture.md
// test strategy: deterministic via Debug only launch argument seeding). This whole file
// compiles into Development builds only; Internal and Release never contain the wipe or
// the seed, so a shipped app cannot lose data to a launch argument.

/// The launch argument that switches a Debug build into deterministic UI test seeding.
/// XCUITests launch with "-CYBERSEND_UI_TEST_SEED 1"; the value is ignored and only the
/// presence of the argument matters.
let uiTestSeedArgument = "-CYBERSEND_UI_TEST_SEED"

enum UITestSeed {
    /// Removes the whole database directory so every seeded launch starts from an empty,
    /// freshly migrated database regardless of earlier runs (deterministic smoke tests).
    static func wipeDatabase(at documentDirectory: URL) throws {
        let directory = documentDirectory
            .appendingPathComponent(CyberSendDatabase.directoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Seeds exactly the data the smoke set relies on: one gym with two climbs (V3, V4),
    /// a closed session with four attempts grouped over both climbs (US-22 history), and
    /// one open session (US-11.2, the quick log surface). Names and timestamps are fixed
    /// so accessibility assertions stay deterministic across launches. It then writes one
    /// local backup and renames the gym, so the settings restore smoke can prove that a
    /// confirmed restore reverts to the archived name while a cancelled dialog leaves the
    /// rename alone (docs/reviews.md restore confirmation obligation).
    static func seed(repos: Repositories, documentDirectory: URL) throws {
        let gym = try repos.gyms.create(CreateGymInput(name: "Boulder Lab"))
        let climbOne = try repos.climbs.create(
            CreateClimbInput(gymId: gym.id, name: "Climb One", gradeSystemId: defaultGradeSystemID, gradeLevelId: "v3")
        )
        let climbTwo = try repos.climbs.create(
            CreateClimbInput(gymId: gym.id, name: "Climb Two", gradeSystemId: defaultGradeSystemID, gradeLevelId: "v4")
        )

        // Closed history session: Climb One send then project, Climb Two fail then send.
        let closed = try repos.sessions.create(
            CreateSessionInput(gymId: gym.id, startedAt: "2026-10-19T10:00:00.000Z", notes: "Seeded session")
        )
        _ = try repos.attempts.logAttempt(
            LogAttemptInput(sessionId: closed.id, climbId: climbOne.id, outcome: .send, attemptedAt: "2026-10-19T10:02:00.000Z")
        )
        _ = try repos.attempts.logAttempt(
            LogAttemptInput(sessionId: closed.id, climbId: climbOne.id, outcome: .project, attemptedAt: "2026-10-19T10:05:00.000Z")
        )
        _ = try repos.attempts.logAttempt(
            LogAttemptInput(sessionId: closed.id, climbId: climbTwo.id, outcome: .fail, attemptedAt: "2026-10-19T10:08:00.000Z")
        )
        _ = try repos.attempts.logAttempt(
            LogAttemptInput(sessionId: closed.id, climbId: climbTwo.id, outcome: .send, attemptedAt: "2026-10-19T10:12:00.000Z")
        )
        _ = try repos.sessions.close(
            id: closed.id,
            input: CloseSessionInput(endedAt: "2026-10-19T11:00:00.000Z", rpe: .set(7), notes: .set("Seeded session"))
        )

        // Open session for the quick log smoke (at most one open session, US-11.2).
        _ = try repos.sessions.create(
            CreateSessionInput(gymId: gym.id, startedAt: "2026-10-20T09:00:00.000Z")
        )

        // One local backup, then a post backup edit it does not contain: the settings
        // restore smoke restores (reverts to "Boulder Lab") or cancels (keeps the
        // rename) behind the destructive confirmation dialog.
        _ = try writeBackup(repos: repos, documentDirectory: documentDirectory)
        _ = try repos.gyms.rename(id: gym.id, name: "Boulder Lab Renamed")
    }
}
#endif
