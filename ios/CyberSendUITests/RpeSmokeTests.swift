import XCTest

// Per attempt RPE smoke (M4 UI overhaul): the quick log card carries an effort picker and
// the logged attempt row shows the chosen RPE. The menu picker is the one part of this
// feature that only a UI test can prove, because it is pure SwiftUI control wiring over a
// store call the unit tests already cover.

@MainActor
final class RpeSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEffortChosenBeforeLoggingIsShownOnTheAttempt() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        XCTAssertTrue(
            app.buttons["session.card.open"].waitForExistence(timeout: 20),
            "the seeded open session renders its open action"
        )
        app.buttons["session.card.open"].tap()

        let effort = app.descendants(matching: .any)["session.attempt-rpe"]
        XCTAssertTrue(effort.waitForExistence(timeout: 10), "the quick log card exposes per attempt effort")
        effort.tap()

        let eight = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'RPE 8'")).firstMatch
        XCTAssertTrue(eight.waitForExistence(timeout: 10), "the effort menu lists the 1 to 10 range")
        eight.tap()

        let send = app.buttons["outcome.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "the outcome buttons are on the same screen")
        send.tap()

        let firstAttempt = app.staticTexts["session.attempt.0"]
        XCTAssertTrue(firstAttempt.waitForExistence(timeout: 10), "the logged attempt is listed")
        XCTAssertTrue(firstAttempt.label.contains("RPE 8"), "the attempt row carries the chosen effort: \(firstAttempt.label)")
    }
}
