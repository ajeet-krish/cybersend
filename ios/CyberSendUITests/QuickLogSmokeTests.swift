import XCTest

// Quick log smoke (docs/architecture.md test strategy: the smoke set stays tiny and is
// deterministic via Debug only launch argument seeding). This test encodes the worst case
// quick log path from the logbook home with tap accounting (docs/requirements.md US-12.5,
// at most 4 taps per attempt):
//
//   1. tap the open session card (pushes the session screen)
//   2. tap the climb dropdown (opens the climb menu)
//   3. tap a climb (switch the quick log climb)
//   4. tap Fail (opens the fall hold sheet)
//   5. tap Skip (saves the attempt without a hold)
//
// The test fails on a sixth tap: the tap helper refuses to exceed the budget, and the
// final assertions prove the attempt saved without any further interaction. The M3
// variant swaps Skip for a real hold row (the climb's seeded climb_holds), keeping the
// same 5 tap budget with the fall hold recorded. The dropdown costs one more tap than
// the old chip strip only when the climb changes; logging against the already selected
// climb stays at 3 taps (open, outcome, save).

@MainActor
final class QuickLogSmokeTests: XCTestCase {
    private var taps = 0
    private let tapBudget = 5

    override func setUpWithError() throws {
        continueAfterFailure = false
        taps = 0
    }

    func testLogAttemptWithinFiveTaps() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        // 1: open the seeded session from the logbook home.
        XCTAssertTrue(
            app.buttons["session.card.open"].waitForExistence(timeout: 20),
            "the seeded open session renders its open action"
        )
        tap(app.buttons["session.card.open"])

        // 2: open the quick log climb dropdown.
        tap(app.buttons["session.climb.select"])

        // 3: switch the quick log climb to the seeded Climb Two.
        let climbOption = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Climb Two'")).firstMatch
        XCTAssertTrue(climbOption.waitForExistence(timeout: 10), "the dropdown lists the gym's climbs")
        tap(climbOption)

        // 4: tap Fail, which opens the fall hold sheet (US-12.3). The wait is polling,
        // not a tap, so the budget accounting below stays exact.
        let failButton = app.buttons["outcome.fail"]
        XCTAssertTrue(failButton.waitForExistence(timeout: 10), "the open session screen shows the three outcome buttons")
        XCTAssertTrue(failButton.isEnabled, "outcome buttons are enabled for a fresh climb")
        tap(failButton)

        // 5: skip the fall hold; the skip saves the attempt (worst case 5 tap path).
        XCTAssertTrue(
            app.buttons["fall.sheet.skip"].waitForExistence(timeout: 10),
            "fail opens the fall hold sheet with a skip"
        )
        tap(app.buttons["fall.sheet.skip"])

        XCTAssertEqual(taps, tapBudget, "the worst case quick log path uses exactly the 5 budgeted taps")

        // No further taps: the attempt must already be saved and visible.
        let counter = app.staticTexts["session.attempts.count"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10), "the attempt list renders after the save")
        XCTAssertEqual(counter.label, "1 attempt", "the attempt saved on the last tap with no extra tap needed")

        let newestAttempt = app.staticTexts["session.attempt.0"]
        XCTAssertTrue(newestAttempt.exists, "the logged attempt is listed newest first")
        XCTAssertTrue(newestAttempt.label.contains("Fail"), "the logged attempt records the fail outcome")
        XCTAssertTrue(newestAttempt.label.contains("Climb Two"), "the attempt lands on the selected climb")
    }

    func testLogAttemptWithHoldRowAsTheFifthTap() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        // 1: open the seeded session from the logbook home.
        XCTAssertTrue(
            app.buttons["session.card.open"].waitForExistence(timeout: 20),
            "the seeded open session renders its open action"
        )
        tap(app.buttons["session.card.open"])

        // 2 and 3: open the quick log climb dropdown and switch to the seeded Climb Two
        // (the climb with real holds tagged on its wall photo, M3).
        tap(app.buttons["session.climb.select"])
        let climbOption = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Climb Two'")).firstMatch
        XCTAssertTrue(climbOption.waitForExistence(timeout: 10), "the dropdown lists the gym's climbs")
        tap(climbOption)

        // 4: tap Fail, which opens the fall hold sheet with the climb's real holds.
        let failButton = app.buttons["outcome.fail"]
        XCTAssertTrue(failButton.waitForExistence(timeout: 10), "the open session screen shows the three outcome buttons")
        tap(failButton)

        // 5: a real hold row is the last tap and saves the attempt with the fall hold.
        let holdRow = app.buttons["fall.hold.1"]
        XCTAssertTrue(holdRow.waitForExistence(timeout: 10), "the fall hold sheet lists the climb's real holds")
        XCTAssertTrue(holdRow.label.contains("intermediate hold"), "hold 2 is the seeded intermediate hold")
        tap(holdRow)

        XCTAssertEqual(taps, tapBudget, "the hold row quick log path uses exactly the 5 budgeted taps")

        // No further taps: the tap helper refuses an extra tap, and the attempt must
        // already be saved with its fall hold.
        let newestAttempt = app.staticTexts["session.attempt.0"]
        XCTAssertTrue(newestAttempt.waitForExistence(timeout: 10), "the attempt list renders after the save")
        XCTAssertTrue(newestAttempt.label.contains("Fail"), "the logged attempt records the fail outcome")
        XCTAssertTrue(
            newestAttempt.label.contains("Fell on intermediate hold"),
            "the attempt records the fall hold from the 4th tap row"
        )
    }

    /// Counts taps against the quick log budget and fails before an extra tap can happen,
    /// so a regression that adds a step fails loudly at the extra tap, not at a timeout.
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        taps += 1
        XCTAssertLessThanOrEqual(
            taps,
            tapBudget,
            "quick log path needs tap \(taps) of a \(tapBudget) tap budget (US-12.5)",
            file: file,
            line: line
        )
        element.tap()
    }
}
