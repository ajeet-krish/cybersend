import XCTest

// Session history smoke (docs/architecture.md test strategy; docs/requirements.md US-22):
// open the seeded closed session from the sessions tab and assert the attempts render
// grouped per climb with outcomes, fall hold labels absent (no holds until M3), the RPE,
// and the in progress badge on the separate open session row. Deterministic via the same
// Debug only launch argument seeding as QuickLogSmokeTests (seed data in
// ios/App/UITestSeed.swift).

@MainActor
final class HistorySmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSeededClosedSessionShowsGroupedAttempts() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Sessions"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Sessions"].tap()

        // History rows: 0 is the open session with the in progress badge, 1 is the closed
        // seeded session with its RPE (US-22.1: gym, date, RPE, attempt count).
        XCTAssertTrue(app.staticTexts["history.row.0.badge"].waitForExistence(timeout: 10), "the open session shows the in progress badge")
        XCTAssertTrue(app.staticTexts["history.row.1.rpe"].exists, "the closed session shows its RPE")
        XCTAssertTrue(app.staticTexts["history.row.1.attempts"].label.contains("4"), "the closed session shows its attempt count")
        XCTAssertTrue(app.staticTexts["history.row.0.gym"].label.contains("Boulder Lab"), "history rows show the gym name")

        app.buttons["history.row.1"].tap()

        // US-22.2: attempts grouped by climb with outcomes. Seeded order: Climb One first
        // (send, fail), Climb Two second (fail, send).
        XCTAssertTrue(app.staticTexts["session.group.0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["session.group.0"].label.contains("Climb One"), "group 0 is Climb One with its grade")
        XCTAssertTrue(app.staticTexts["session.group.0"].label.contains("V3"), "the group title carries the grade label")
        XCTAssertTrue(app.staticTexts["session.group.1"].label.contains("Climb Two"), "group 1 is Climb Two")
        XCTAssertTrue(app.staticTexts["session.rpe"].label.contains("RPE 7"), "the detail header shows the session RPE")

        XCTAssertTrue(app.buttons["session.attempt.0.0.edit"].label.contains("Send"), "Climb One attempt 1 is a send")
        XCTAssertTrue(app.buttons["session.attempt.0.1.edit"].label.contains("Fail"), "Climb One attempt 2 is a fail")
        XCTAssertTrue(app.buttons["session.attempt.1.0.edit"].label.contains("Fail"), "Climb Two attempt 1 is a fail")
        XCTAssertTrue(app.buttons["session.attempt.1.1.edit"].label.contains("Send"), "Climb Two attempt 2 is a send")

        // No fall hold labels: the seed logs attempts without holds (holds arrive M3).
        XCTAssertFalse(app.staticTexts["session.attempt.1.0.hold"].exists, "no fall hold label without holds")
    }
}
