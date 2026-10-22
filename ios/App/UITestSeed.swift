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

/// The launch argument that adds the canvas performance fixture: a climb with a
/// synthetic wall photo and this many tagged holds, for example
/// "-CYBERSEND_UI_TEST_SEED_HOLDS 100" (M3, US-18.3 fps gate with the DEVELOPMENT FPS
/// HUD). Presence alone switches a Debug build into seeding mode, same wipe semantics.
let uiTestSeedHoldsArgument = "-CYBERSEND_UI_TEST_SEED_HOLDS"

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
    ///
    /// M3 Task 4 adds the tagging fixtures: Climb Two gains a synthetic wall photo plus
    /// three real holds with roles (start, intermediate, top) at fixed normalized
    /// positions, so the fall hold smoke picks real climb_holds rows and the photo path
    /// renders the real canvas; Climb One stays bare so the tagging smoke can add its own
    /// photo and tag fresh holds. Deterministic hold ids keep the fixtures byte stable.
    ///
    /// M3 Task 5 adds the stats fixtures: a closed "stats" session dated before the
    /// history session (so history row 0 stays the open session and row 1 stays the
    /// four-attempt closed session the history and restore smokes assert on) with fall
    /// attempts carrying the seeded Climb Two holds, driving the stats dashboard: 9
    /// attempts total, three sends, one flash, and heatmap markers on all three holds.
    static func seed(repos: Repositories, documentDirectory: URL) throws {
        let gym = try repos.gyms.create(CreateGymInput(name: "Boulder Lab"))
        let climbOne = try repos.climbs.create(
            CreateClimbInput(
                gymId: gym.id,
                name: "Climb One",
                gradeSystemId: defaultGradeSystemID,
                gradeLevelId: "v3",
                notes: "Match the left crimp, then stand up on the right gaston.",
                categories: [.slab, .technical]
            )
        )
        let climbTwo = try repos.climbs.create(
            CreateClimbInput(
                gymId: gym.id,
                name: "Climb Two",
                gradeSystemId: defaultGradeSystemID,
                gradeLevelId: "v4",
                notes: "Keep the hips close on the top out.",
                categories: [.overhang, .dyno]
            )
        )

        // Closed history session: Climb One send then fail, Climb Two fail then send.
        let closed = try repos.sessions.create(
            CreateSessionInput(gymId: gym.id, startedAt: "2026-10-19T10:00:00.000Z", notes: "Seeded session")
        )
        _ = try repos.attempts.logAttempt(
            LogAttemptInput(
                sessionId: closed.id,
                climbId: climbOne.id,
                outcome: .send,
                attemptedAt: "2026-10-19T10:02:00.000Z",
                rpe: 8
            )
        )
        _ = try repos.attempts.logAttempt(
            LogAttemptInput(
                sessionId: closed.id,
                climbId: climbOne.id,
                outcome: .fail,
                notes: "Slid off the crimp",
                attemptedAt: "2026-10-19T10:05:00.000Z",
                rpe: 9
            )
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

        // M3 tagging fixtures: real holds plus a wall photo on Climb Two (Climb One
        // stays bare for the tagging smoke). These precede the stats session so the
        // fall attempts can carry the seeded holds.
        try seedHoldingClimbFixtures(repos: repos, documentDirectory: documentDirectory, climbId: climbTwo.id)

        // M3 Task 5 stats fixtures (US-23): a closed session dated before the history
        // session so the history rows keep their indices (row 0 open, row 1 the four
        // attempt session the history and restore smokes assert on), with fall attempts
        // carrying the seeded Climb Two holds. Totals across both closed sessions: 10
        // attempts, 4 sends (3 sends plus 1 flash), 6 falls, and a 3 marker heatmap on
        // Climb Two's wall photo.
        let stats = try repos.sessions.create(
            CreateSessionInput(gymId: gym.id, startedAt: "2026-10-18T10:00:00.000Z", notes: "Seeded stats session")
        )
        let statsAttempts: [(climbId: String, outcome: AttemptOutcome, holdId: String?, at: String)] = [
            (climbTwo.id, .fail, "seed.hold.intermediate", "2026-10-18T10:03:00.000Z"),
            (climbTwo.id, .fail, "seed.hold.start", "2026-10-18T10:07:00.000Z"),
            (climbTwo.id, .fail, "seed.hold.top", "2026-10-18T10:11:00.000Z"),
            (climbTwo.id, .send, nil, "2026-10-18T10:16:00.000Z"),
            (climbOne.id, .flash, nil, "2026-10-18T10:20:00.000Z"),
            (climbOne.id, .fail, nil, "2026-10-18T10:24:00.000Z"),
        ]
        for attempt in statsAttempts {
            _ = try repos.attempts.logAttempt(LogAttemptInput(
                sessionId: stats.id,
                climbId: attempt.climbId,
                outcome: attempt.outcome,
                fallOnHoldId: attempt.holdId,
                attemptedAt: attempt.at
            ))
        }
        _ = try repos.sessions.close(
            id: stats.id,
            input: CloseSessionInput(endedAt: "2026-10-18T11:00:00.000Z", rpe: .set(6), notes: .set("Seeded stats session"))
        )

        // Open session for the quick log smoke, created last so the one open session
        // rule (US-11.2) holds at the end of seeding.
        let open = try repos.sessions.create(
            CreateSessionInput(gymId: gym.id, startedAt: "2026-10-20T09:00:00.000Z")
        )
        try seedSessionMedia(repos: repos, documentDirectory: documentDirectory, sessionId: open.id)

        // The canvas performance fixture: "-CYBERSEND_UI_TEST_SEED_HOLDS 100" adds a
        // climb with a synthetic photo and N holds at deterministic grid positions.
        if let holdCount = uiTestSeedHoldCount(), holdCount > 0 {
            try seedPerfClimb(repos: repos, documentDirectory: documentDirectory, gymId: gym.id, holdCount: holdCount)
        }

        // One local backup, then a post backup edit it does not contain: the settings
        // restore smoke restores (reverts to "Boulder Lab") or cancels (keeps the
        // rename) behind the destructive confirmation dialog.
        _ = try writeBackup(repos: repos, documentDirectory: documentDirectory)
        _ = try repos.gyms.rename(id: gym.id, name: "Boulder Lab Renamed")
    }

    /// The hold count for the performance fixture; nil when the argument is absent or
    /// not a positive integer.
    static func uiTestSeedHoldCount() -> Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: uiTestSeedHoldsArgument), index + 1 < arguments.count else {
            return nil
        }
        guard let count = Int(arguments[index + 1]), count > 0 else { return nil }
        return count
    }

    // MARK: - Tagging fixtures

    /// Fixed timestamps for the seeded holds and photo, so exports and labels stay
    /// deterministic across launches.
    private static let fixtureTimestamp = "2026-10-20T09:05:00.000Z"

    /// Fixed UUID shaped photo ids (MediaStorage validates photo ids as UUIDs) so the
    /// seeded fixtures stay deterministic across launches.
    private static let climbTwoPhotoID = "00000000-0000-4000-8000-0000000000c2"
    private static let perfPhotoID = "00000000-0000-4000-8000-0000000000cf"

    /// Three role tagged holds on the climb plus its synthetic wall photo. Hold rows go
    /// through createRestoring so ids, ordinals (the beta order), and timestamps are all
    /// fixed strings instead of random UUIDs.
    private static func seedHoldingClimbFixtures(
        repos: Repositories,
        documentDirectory: URL,
        climbId: String
    ) throws {
        let fixtures: [(suffix: String, x: Double, y: Double, role: HoldRole)] = [
            ("start", 0.30, 0.70, .start),
            ("intermediate", 0.45, 0.45, .intermediate),
            ("top", 0.55, 0.20, .top),
        ]
        for (index, fixture) in fixtures.enumerated() {
            let hold = Hold(
                id: "seed.hold.\(fixture.suffix)",
                climbId: climbId,
                xNorm: fixture.x,
                yNorm: fixture.y,
                radiusNorm: 0.03,
                role: fixture.role,
                source: .manual,
                ordinal: index + 1,
                createdAt: fixtureTimestamp,
                updatedAt: fixtureTimestamp
            )
            try repos.holds.createRestoring(hold)
        }
        try seedWallPhoto(
            repos: repos,
            documentDirectory: documentDirectory,
            climbId: climbId,
            photoID: climbTwoPhotoID
        )
    }

    /// A climb with a synthetic wall photo and holdCount holds in a deterministic 10 by
    /// rows grid, roles cycling start, intermediate, top (the US-18.3 fps fixture).
    private static func seedPerfClimb(
        repos: Repositories,
        documentDirectory: URL,
        gymId: String,
        holdCount: Int
    ) throws {
        let climb = try repos.climbs.create(
            CreateClimbInput(gymId: gymId, name: "Perf Wall", gradeSystemId: defaultGradeSystemID, gradeLevelId: "v3")
        )
        try seedWallPhoto(repos: repos, documentDirectory: documentDirectory, climbId: climb.id, photoID: perfPhotoID)
        let roles: [HoldRole] = [.start, .intermediate, .top]
        for index in 0..<holdCount {
            let hold = Hold(
                id: String(format: "seed.perf.hold.%03d", index),
                climbId: climb.id,
                xNorm: 0.06 + Double(index % 10) * 0.095,
                yNorm: 0.06 + Double(index / 10) * 0.09,
                radiusNorm: 0.025,
                role: roles[index % roles.count],
                source: .manual,
                ordinal: index,
                createdAt: fixtureTimestamp,
                updatedAt: fixtureTimestamp
            )
            try repos.holds.createRestoring(hold)
        }
    }

    /// Writes the deterministic wall JPEG straight to the media storage and creates its
    /// photo row (working copy and thumb), bypassing the async ingest: seeding runs
    /// synchronously at launch and the synthetic source already matches the working copy
    /// policy (1200 by 1600 is within the 2048 px long edge).
    /// One session photo and one session clip, so the session media block renders its photo
    /// strip, its video row, and the player wiring without a system picker (UI overhaul).
    /// The clip bytes are deliberately not a real movie: the smoke proves the row, the
    /// duration label, and that a player sheet presents, not codec playback.
    private static func seedSessionMedia(
        repos: Repositories,
        documentDirectory: URL,
        sessionId: String
    ) throws {
        let storage = MediaStorage(root: documentDirectory)
        let photoID = "00000000-0000-4000-8000-0000000000d1"
        if let jpeg = SyntheticPhotoSource.wallJPEG() {
            let workingUri = try storage.writeWorking(jpeg, photoID: photoID)
            let thumbUri = try storage.writeThumb(jpeg, photoID: photoID)
            _ = try repos.media.createPhoto(CreatePhotoInput(
                id: photoID,
                uri: workingUri,
                width: SyntheticPhotoSource.width,
                height: SyntheticPhotoSource.height,
                climbId: nil,
                sessionId: sessionId,
                thumbUri: thumbUri,
                originalUri: nil,
                source: .library,
                capturedAt: fixtureTimestamp
            ))
        }

        let videoID = "00000000-0000-4000-8000-0000000000d2"
        let videoBytes = Data("seed clip placeholder".utf8)
        let videoUri = try storage.writeVideo(videoBytes, videoID: videoID, fileExtension: "mp4")
        _ = try repos.media.createVideo(CreateVideoInput(
            uri: videoUri,
            sessionId: sessionId,
            climbId: nil,
            width: 1080,
            height: 1920,
            durationMs: 12000,
            fps: nil,
            poseStatus: .none,
            retentionClass: .keep
        ))
    }

    private static func seedWallPhoto(
        repos: Repositories,
        documentDirectory: URL,
        climbId: String,
        photoID: String
    ) throws {
        guard let jpeg = SyntheticPhotoSource.wallJPEG() else {
            throw DomainValidationError("seed_photo_failed", "The synthetic wall photo could not be generated.")
        }
        let storage = MediaStorage(root: documentDirectory)
        let workingUri = try storage.writeWorking(jpeg, photoID: photoID)
        let thumbUri = try storage.writeThumb(jpeg, photoID: photoID)
        _ = try repos.media.createPhoto(CreatePhotoInput(
            id: photoID,
            uri: workingUri,
            width: SyntheticPhotoSource.width,
            height: SyntheticPhotoSource.height,
            climbId: climbId,
            sessionId: nil,
            thumbUri: thumbUri,
            originalUri: nil,
            source: .library,
            capturedAt: fixtureTimestamp
        ))
    }
}
#endif
