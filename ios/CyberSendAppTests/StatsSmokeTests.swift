import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import XCTest
@testable import CyberSend

// M3 Task 5 stats UI wiring smoke (docs/requirements.md US-23): the stats store wired
// into the app environment aggregates the Debug only seeded fixtures into the summary
// the dashboard cards render, and the fall heatmap carries membership backed markers
// over the seeded wall photo. The StatsStore level behavior (rates, buckets, the 10k
// budget) stays covered by the package StatsStoreTests suite.

@MainActor
final class StatsSmokeTests: XCTestCase {
    /// Bootstraps a Development environment on a temporary root with the deterministic
    /// UI test seed applied (the same seed XCUITest launches with).
    private func seededEnvironment() throws -> AppEnvironment {
        let root = try makeTemporaryRoot(label: "stats-seed")
        try UITestSeed.wipeDatabase(at: root)
        let environment = try XCTUnwrap(
            AppBootstrap(documentDirectory: root, variant: .development).run().environment
        )
        try UITestSeed.seed(repos: environment.repos, documentDirectory: root)
        return environment
    }

    func testSeededStatsRenderTheSummaryAndHeatmap() throws {
        let environment = try seededEnvironment()
        defer { removeTemporaryRoot(environment.documentDirectory) }

        let store = StatsStore(repos: environment.repos, storage: environment.media.storage)
        store.refresh()

        XCTAssertNil(store.lastErrorMessage, "the seeded dashboard aggregates without errors")

        // Summary over the two seeded closed sessions (history 4 attempts plus stats
        // 6 attempts): 10 attempts, 3 sends plus 1 flash, 6 fails (US-23.1). The project
        // outcome retired in M4, so the seeded non send attempts are all fails.
        XCTAssertEqual(store.summary.attempts, 10)
        XCTAssertEqual(store.summary.totalSends, 4)
        XCTAssertEqual(store.summary.flashes, 1)
        XCTAssertEqual(store.summary.fails, 6)
        XCTAssertEqual(store.summary.flashRate, 0.1, accuracy: 1e-9)
        XCTAssertEqual(store.summary.sendRate, 0.4, accuracy: 1e-9)

        // By grade rows exist for both seeded grades with guarded rates.
        let v3 = try XCTUnwrap(store.gradeRows.first { $0.levelId == "v3" })
        XCTAssertEqual(v3.attempts, 4, "Climb One (V3): send, fail, flash, fail")
        XCTAssertEqual(v3.totalSends, 2)
        let v4 = try XCTUnwrap(store.gradeRows.first { $0.levelId == "v4" })
        XCTAssertEqual(v4.attempts, 6, "Climb Two (V4): fail, send, fail, fail, fail, send")
        XCTAssertEqual(v4.totalSends, 2)

        // Falls by role: 1 intermediate, 1 start, 1 top, 3 unassigned (the seeded
        // fall attempts without a hold).
        let roleFalls = Dictionary(uniqueKeysWithValues: store.roleDistribution.map { ($0.bucket, $0.falls) })
        XCTAssertEqual(roleFalls[.start], 1)
        XCTAssertEqual(roleFalls[.intermediate], 1)
        XCTAssertEqual(roleFalls[.top], 1)
        XCTAssertEqual(roleFalls[.unassigned], 3)

        // The heatmap preselects Climb Two (the most fallen climb) and carries one
        // marker per seeded hold that recorded a fall, over its wall photo.
        XCTAssertEqual(store.selectedClimbId, store.climbSummaries.first?.climbId)
        let heatmap = try XCTUnwrap(store.heatmap)
        XCTAssertNotNil(heatmap.photoId, "the seeded wall photo rides the heatmap")
        XCTAssertEqual(heatmap.markers.count, 3)
        XCTAssertEqual(
            Set(heatmap.markers.map(\.holdId)),
            ["seed.hold.start", "seed.hold.intermediate", "seed.hold.top"]
        )
        XCTAssertTrue(heatmap.markers.allSatisfy { $0.fallCount == 1 })
    }

    func testFreshDatabaseRendersTheEmptyStateWithoutErrors() throws {
        let root = try makeTemporaryRoot(label: "stats-empty")
        defer { removeTemporaryRoot(root) }

        let environment = try XCTUnwrap(
            AppBootstrap(documentDirectory: root, variant: .development).run().environment
        )

        let store = StatsStore(repos: environment.repos, storage: environment.media.storage)
        store.refresh()

        // The dashboard's empty state gate: zero attempts means the StatsView renders
        // the "No attempts yet" empty state instead of any section.
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertEqual(store.summary.attempts, 0)
        XCTAssertTrue(store.gradeRows.isEmpty)
        XCTAssertTrue(store.weeklyVolume.isEmpty)
        XCTAssertTrue(store.climbSummaries.isEmpty)
        XCTAssertNil(store.selectedClimbId)
        XCTAssertNil(store.heatmap)
    }
}
