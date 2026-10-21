import XCTest

// Problems catalog smoke (UI overhaul): the fifth tab lists the seeded problems with their
// grade and attempt rollup, opens the per problem history, and archives a problem without
// losing that history. The catalog is the one new surface where list, detail, and archive
// wiring meet, so the smoke walks all three.

@MainActor
final class ProblemsCatalogSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCatalogListsSeedProblemsAndOpensHistory() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Problems"].waitForExistence(timeout: 20), "the catalog is its own tab")
        app.tabBars.buttons["Problems"].tap()

        let climbOne = app.staticTexts["Climb One"]
        XCTAssertTrue(climbOne.waitForExistence(timeout: 10), "the seeded problem is listed")
        XCTAssertTrue(app.staticTexts["Climb Two"].exists, "both seeded problems are listed")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label == 'V3'")).firstMatch.exists,
            "the row carries the grade label"
        )
        XCTAssertTrue(
            app.staticTexts["Match the left crimp, then stand up on the right gaston."].exists,
            "the row previews the problem details"
        )

        climbOne.tap()

        XCTAssertTrue(app.staticTexts["problem.name"].waitForExistence(timeout: 10), "the detail screen opens")
        XCTAssertEqual(app.staticTexts["problem.name"].label, "Climb One")
        XCTAssertEqual(app.staticTexts["problem.grade"].label, "V3")
        XCTAssertTrue(
            app.staticTexts["problem.details"].label.contains("left crimp"),
            "the detail screen shows the problem details"
        )
        XCTAssertTrue(
            app.staticTexts["problem.history.summary"].label.contains("Sent 2 times"),
            "the history summary counts sends and flashes: \(app.staticTexts["problem.history.summary"].label)"
        )
        XCTAssertTrue(
            app.staticTexts["problem.history.summary"].label.contains("4 attempts"),
            "the history summary counts every attempt"
        )
        XCTAssertTrue(app.staticTexts["problem.history.0.date"].exists, "the newest attempt is listed first")
        XCTAssertTrue(app.staticTexts["problem.history.0.rpe"].label.contains("9"), "per attempt effort shows in history")
        XCTAssertTrue(app.staticTexts["problem.history.1.rpe"].label.contains("8"))

        // Archive keeps the history: the manage action flips the state in place.
        app.buttons["problem.archive"].tap()
        XCTAssertTrue(app.staticTexts["problem.archived"].waitForExistence(timeout: 10), "the header marks it archived")
        XCTAssertTrue(app.buttons["problem.archive"].label.contains("Unarchive"), "the action flips to unarchive")
        XCTAssertTrue(app.staticTexts["problem.history.0.date"].exists, "archiving does not clear the history")
    }

    func testArchivedProblemsAreHiddenUntilToggled() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Problems"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Problems"].tap()
        XCTAssertTrue(app.staticTexts["Climb Two"].waitForExistence(timeout: 10))
        app.staticTexts["Climb Two"].tap()

        XCTAssertTrue(app.buttons["problem.archive"].waitForExistence(timeout: 10))
        app.buttons["problem.archive"].tap()
        XCTAssertTrue(app.staticTexts["problem.archived"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Problems"].tap()

        // Hidden by default once archived, visible again under the toggle.
        XCTAssertTrue(app.staticTexts["Climb One"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Climb Two"].exists, "an archived problem leaves the default catalog")

        let toggle = app.switches["problems.show-archived"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        XCTAssertTrue(app.staticTexts["Climb Two"].waitForExistence(timeout: 10), "the toggle brings it back")
    }
}
