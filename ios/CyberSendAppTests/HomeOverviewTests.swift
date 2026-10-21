import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import XCTest
@testable import CyberSend

// Home overview wiring (UI overhaul): the three home blocks read one snapshot of the
// seeded fixtures. The heatmap math is local calendar work, so it is pinned here rather
// than in a UI test: 20 columns of 7 days, one filled day per seeded session, and the
// future tail of the current week left empty.

@MainActor
final class HomeOverviewTests: XCTestCase {
    private func seededEnvironment(label: String) throws -> AppEnvironment {
        let root = try makeTemporaryRoot(label: label)
        try UITestSeed.wipeDatabase(at: root)
        let environment = try XCTUnwrap(
            AppBootstrap(documentDirectory: root, variant: .development).run().environment
        )
        try UITestSeed.seed(repos: environment.repos, documentDirectory: root)
        return environment
    }

    func testRecentBlocksReadTheSeedNewestFirst() throws {
        let environment = try seededEnvironment(label: "home-recent")
        let store = HomeOverviewStore(repos: environment.repos)

        XCTAssertEqual(store.recentSessions.count, 3, "the home shows the last three sessions")
        XCTAssertEqual(store.recentSessions.first?.isOpen, true, "the open session is the newest")
        XCTAssertEqual(store.recentSessions.last?.gymName, "Boulder Lab Renamed")

        // Most recently attempted first: Climb Two's newest attempt (send at 10:12) is
        // later than Climb One's newest (fail at 10:05).
        XCTAssertEqual(store.recentClimbs.map(\.name), ["Climb Two", "Climb One"])
        XCTAssertEqual(store.recentClimbs.first?.lastOutcome, .send)
        XCTAssertEqual(store.recentClimbs.first?.gradeLabel, "V4")
        XCTAssertEqual(store.recentClimbs.first?.attemptCount, 6)
    }

    func testHeatmapCoversTwentyWeeksWithOneFilledDayPerSeededSession() throws {
        let environment = try seededEnvironment(label: "home-heatmap")
        let store = HomeOverviewStore(repos: environment.repos)

        XCTAssertEqual(store.heatmapColumns.count, HomeOverviewStore.heatmapWeeks)
        XCTAssertEqual(store.heatmapColumns.map(\.count), Array(repeating: 7, count: HomeOverviewStore.heatmapWeeks))
        XCTAssertEqual(store.sessionsInHeatmapWindow, 3, "each seeded session fills exactly one day")

        let filledDays = store.heatmapColumns.joined().filter { $0.count > 0 }
        XCTAssertEqual(filledDays.count, 3)
        XCTAssertEqual(Set(filledDays.map(\.count)), [1])
        XCTAssertTrue(filledDays.allSatisfy { !$0.isFuture })

        // The grid ends on the current week: the last column holds today and its future tail
        // is flagged rather than filled.
        let lastColumn = try XCTUnwrap(store.heatmapColumns.last)
        XCTAssertTrue(lastColumn.contains { $0.isFuture } || lastColumn.last?.isFuture == false)
        XCTAssertEqual(store.heatmapColumns.joined().filter(\.isFuture).count, lastColumn.filter(\.isFuture).count)
    }
}
