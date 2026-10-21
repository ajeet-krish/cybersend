import XCTest

// Fall hold smoke (docs/architecture.md test strategy, M3 US-12.3 and US-21): the fail
// prompt lists the climb's REAL holds from climb_holds with role labels, a single row
// tap saves the attempt inside the 4 tap budget (the row tap is the 4th tap, proven by
// QuickLogSmokeTests), and the attempt row shows the hold name with no further
// interaction. The "Show on photo" path renders the climb's synthetic wall photo in the
// read only canvas and one tap on a hold saves fall_on_hold_id the same way.

@MainActor
final class FallHoldSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()
        return app
    }

    /// Opens the seeded open session with Climb Two selected (the climb with seeded
    /// holds and a wall photo), leaving the app on the quick log surface.
    private func openQuickLog(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.buttons["Logbook"].waitForExistence(timeout: 20))
        XCTAssertTrue(
            app.buttons["session.card.open"].waitForExistence(timeout: 10),
            "the seeded open session renders its open action"
        )
        app.buttons["session.card.open"].tap()
        app.buttons["session.climb.select"].tap()
        let climbOption = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Climb Two'")).firstMatch
        XCTAssertTrue(climbOption.waitForExistence(timeout: 10), "the dropdown lists the gym's climbs")
        climbOption.tap()
    }

    func testFailListsRealHoldsAndARowTapSavesTheAttempt() throws {
        let app = launchSeededApp()
        openQuickLog(app)

        let failButton = app.buttons["outcome.fail"]
        XCTAssertTrue(failButton.waitForExistence(timeout: 10), "the open session screen shows the outcome buttons")
        failButton.tap()

        // Real climb_holds rows with role labels in beta order (seed ordinals 1 to 3).
        let startRow = app.buttons["fall.hold.0"]
        XCTAssertTrue(startRow.waitForExistence(timeout: 10), "the fall hold sheet lists the climb's real holds")
        XCTAssertTrue(startRow.label.contains("start hold"), "hold 1 is the seeded start hold (\(startRow.label))")
        XCTAssertTrue(app.buttons["fall.hold.1"].label.contains("intermediate hold"), "hold 2 is the intermediate hold")
        XCTAssertTrue(app.buttons["fall.hold.2"].label.contains("top hold"), "hold 3 is the top hold")

        // One tap on the row saves: the sheet dismisses and the attempt row shows the
        // hold name with no further interaction (the 4 tap budget path).
        startRow.tap()
        let newestAttempt = app.staticTexts["session.attempt.0"]
        XCTAssertTrue(newestAttempt.waitForExistence(timeout: 10), "the attempt list renders after the save")
        XCTAssertTrue(newestAttempt.label.contains("Fail"), "the logged attempt records the fail outcome")
        XCTAssertTrue(
            newestAttempt.label.contains("Fell on start hold"),
            "the attempt row shows the tapped hold name (\(newestAttempt.label))"
        )
    }

    func testFailOnPhotoSavesTheTappedHold() throws {
        let app = launchSeededApp()
        openQuickLog(app)

        let failButton = app.buttons["outcome.fail"]
        XCTAssertTrue(failButton.waitForExistence(timeout: 10))
        failButton.tap()

        // The climb has a wall photo, so the sheet offers the canvas path.
        let showOnPhoto = app.buttons["fall.show-on-photo"]
        XCTAssertTrue(showOnPhoto.waitForExistence(timeout: 10), "a climb with a photo offers Show on photo")
        showOnPhoto.tap()

        let canvas = app.images["fall.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15), "Show on photo renders the read only tagging canvas")

        // Tap the seeded start hold at its fixed normalized position (0.30, 0.70): one
        // tap on the canvas saves fall_on_hold_id, same as a row tap.
        let dimensions = parseDimensions(app.staticTexts["fall.photo.dimensions"].label)
        let frame = canvas.frame
        let fit = min(frame.width / dimensions.width, frame.height / dimensions.height)
        let offsetX = (frame.width - dimensions.width * fit) / 2
        let offsetY = (frame.height - dimensions.height * fit) / 2
        let screenX = offsetX + 0.30 * dimensions.width * fit
        let screenY = offsetY + 0.70 * dimensions.height * fit
        canvas.coordinate(withNormalizedOffset: CGVector(
            dx: screenX / frame.width,
            dy: screenY / frame.height
        )).tap()

        // No further taps: the attempt saved with the tapped hold.
        let newestAttempt = app.staticTexts["session.attempt.0"]
        XCTAssertTrue(newestAttempt.waitForExistence(timeout: 10), "the attempt list renders after the canvas tap")
        XCTAssertTrue(
            newestAttempt.label.contains("Fell on start hold"),
            "the canvas tap saved the tapped hold (\(newestAttempt.label))"
        )
    }

    // MARK: - Helpers

    /// "1,200 by 1,600 pixels" into its pixel size (the label is locale formatted).
    private func parseDimensions(_ label: String) -> (width: CGFloat, height: CGFloat) {
        let parts = label.replacingOccurrences(of: ",", with: "").components(separatedBy: " ")
        guard parts.count >= 3, let width = Double(parts[0]), let height = Double(parts[2]) else {
            XCTFail("the photo dimensions string parses: \(label)")
            return (1200, 1600)
        }
        return (CGFloat(width), CGFloat(height))
    }
}
