import XCTest

// Quick log smoke (docs/architecture.md test strategy: the smoke set stays tiny and is
// deterministic via Debug only launch argument seeding). This test encodes the worst case
// quick log path from the logbook home with tap accounting (docs/requirements.md US-12.5,
// at most 4 taps per attempt):
//
//   1. tap the open session card (pushes the session screen)
//   2. tap a climb chip (switch the quick log climb)
//   3. tap Fail (opens the fall hold sheet)
//   4. tap Skip (saves the attempt without a hold)
//
// The test fails on a fifth tap: the tap helper refuses to exceed the budget, and the
// final assertions prove the attempt saved without any further interaction.

@MainActor
final class QuickLogSmokeTests: XCTestCase {
    private var taps = 0
    private let tapBudget = 4

    override func setUpWithError() throws {
        continueAfterFailure = false
        taps = 0
    }

    func testLogAttemptWithinFourTaps() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        // 1: open the seeded session from the logbook home.
        XCTAssertTrue(
            app.buttons["session.card.open"].waitForExistence(timeout: 20),
            "the seeded open session renders its open action"
        )
        tap(app.buttons["session.card.open"])

        // 2: switch the quick log climb to the seeded Climb Two.
        let climbChip = app.buttons["session.climb.chip.Climb Two"]
        XCTAssertTrue(climbChip.waitForExistence(timeout: 10), "the session screen lists quick log climb chips")
        tap(climbChip)

        // 3: tap Fail, which opens the fall hold sheet (US-12.3). The wait is polling,
        // not a tap, so the budget accounting below stays exact.
        let failButton = app.buttons["outcome.fail"]
        XCTAssertTrue(failButton.waitForExistence(timeout: 10), "the open session screen shows the four outcome buttons")
        XCTAssertTrue(failButton.isEnabled, "outcome buttons are enabled for a fresh climb")
        tap(failButton)

        // 4: skip the fall hold; the skip saves the attempt (worst case 4 tap path).
        XCTAssertTrue(
            app.buttons["fall.sheet.skip"].waitForExistence(timeout: 10),
            "fail opens the fall hold sheet with a skip"
        )
        tap(app.buttons["fall.sheet.skip"])

        XCTAssertEqual(taps, tapBudget, "the worst case quick log path uses exactly the 4 budgeted taps")

        // No further taps: the attempt must already be saved and visible.
        let counter = app.staticTexts["session.attempts.count"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10), "the attempt list renders after the save")
        XCTAssertEqual(counter.label, "1 attempt", "the attempt saved on the 4th tap with no 5th tap needed")

        let newestAttempt = app.staticTexts["session.attempt.0"]
        XCTAssertTrue(newestAttempt.exists, "the logged attempt is listed newest first")
        XCTAssertTrue(newestAttempt.label.contains("Fail"), "the logged attempt records the fail outcome")
        XCTAssertTrue(newestAttempt.label.contains("Climb Two"), "the attempt lands on the selected climb")
    }

    /// Counts taps against the quick log budget and fails before a fifth tap can happen,
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
