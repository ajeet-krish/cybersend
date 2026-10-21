import XCTest

// Stats smoke (docs/architecture.md M3 Task 5, US-23): the Debug only seed adds a closed
// stats session with fall attempts on the seeded Climb Two holds, so the stats tab
// renders the seeded summary (10 attempts, 5 sends, 10 percent flash rate) and the fall
// heatmap carries one marker per seeded fall hold over Climb Two's wall photo. The
// package StatsStoreTests cover the aggregation math; this smoke proves the tab wiring
// and that real seeded data reaches the dashboard.

@MainActor
final class StatsSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSeededStatsRenderSummaryAndHeatmap() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Stats"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Stats"].tap()

        // Summary cards over the seeded sessions (two closed sessions: 4 plus 6
        // attempts, 3 sends plus 1 flash, one flash). The cards are combined
        // accessibility elements, so the query matches any element type.
        let attempts = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "stats.summary.attempts")).firstMatch
        XCTAssertTrue(attempts.waitForExistence(timeout: 10), "the stats tab renders the summary cards")
        XCTAssertTrue(attempts.label.contains("10"), "the summary counts the seeded attempts (\(attempts.label))")
        let sends = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "stats.summary.sends")).firstMatch
        XCTAssertTrue(sends.label.contains("4"), "the summary counts the seeded sends")
        let flashRate = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "stats.summary.flashrate")).firstMatch
        XCTAssertTrue(
            flashRate.label.contains("10%"),
            "the summary shows the seeded flash rate"
        )

        // The by grade table carries both seeded grades.
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "stats.grade.row.")
            ).firstMatch.waitForExistence(timeout: 10),
            "the by grade table renders rows for the seeded grades"
        )

        // The fall heatmap preselects Climb Two (most falls) and marks each seeded
        // fall hold over the wall photo. Elements live inside a ScrollView, so the
        // heatmap scrolls into view first.
        let marker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "stats.heatmap.marker.seed.hold.start")).firstMatch
        scrollIntoView(marker, in: app)
        XCTAssertTrue(marker.waitForExistence(timeout: 10), "the heatmap marks the seeded start hold")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@", "stats.heatmap.marker.seed.hold.intermediate"))
                .firstMatch.exists,
            "the heatmap marks the seeded intermediate hold"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@", "stats.heatmap.marker.seed.hold.top"))
                .firstMatch.exists,
            "the heatmap marks the seeded top hold"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@", "stats.heatmap.photo"))
                .firstMatch.exists,
            "the heatmap overlays the climb's wall photo"
        )
    }

    /// Swipes up until the element is on screen (bounded, so a missing element fails
    /// at the existence assertion instead of looping forever).
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        for _ in 0..<maxSwipes where !element.exists {
            app.swipeUp()
        }
    }
}
