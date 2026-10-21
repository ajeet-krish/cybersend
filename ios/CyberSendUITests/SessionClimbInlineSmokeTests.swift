import XCTest

// Inline climb editor smoke (UI overhaul): a problem can be created from inside the open
// session screen, lands in that session's gym, becomes the selected quick log climb, and
// the sheet continues into the photo section so a wall photo can be added without closing
// and reopening. The last step logs an attempt on the new problem, proving the whole chain
// (create, select, log) with no trip to another tab.

@MainActor
final class SessionClimbInlineSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNewProblemFromSessionIsSelectedAndLoggable() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        XCTAssertTrue(app.buttons["session.card.open"].waitForExistence(timeout: 20))
        app.buttons["session.card.open"].tap()

        let newProblem = app.buttons["session.climb.new"]
        XCTAssertTrue(newProblem.waitForExistence(timeout: 10), "the session screen offers an inline add")
        newProblem.tap()

        let nameField = app.textFields["climb.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "the editor opens as a sheet")
        nameField.tap()
        nameField.typeText("Inline Problem")

        app.buttons["climb.save"].tap()

        // The sheet stays open in edit mode, so the photo section (only rendered for an
        // existing climb) is the proof that the create landed and reloaded in place.
        XCTAssertTrue(
            app.buttons["climb.photo.add"].waitForExistence(timeout: 10),
            "the editor continues into the new problem so its photo can be added now"
        )
        app.buttons["climb.close"].tap()

        let selected = app.staticTexts["session.climb.selected"]
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        XCTAssertEqual(selected.label, "Inline Problem", "the new problem becomes the quick log climb")

        // Log a send on it: the attempt section must accept the freshly created climb.
        app.buttons["outcome.send"].tap()
        let counter = app.staticTexts["session.attempts.count"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10), "the attempt counter renders after logging")
        XCTAssertEqual(counter.label, "1 attempt")
    }

    func testEditProblemFromSessionUpdatesTheSelectedClimb() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        XCTAssertTrue(app.buttons["session.card.open"].waitForExistence(timeout: 20))
        app.buttons["session.card.open"].tap()

        XCTAssertTrue(app.buttons["session.climb.edit"].waitForExistence(timeout: 10))
        app.buttons["session.climb.edit"].tap()

        let nameField = app.textFields["climb.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        // The editor opens on the climb the session has selected; whatever it is, the rename
        // must come back through the quick log label.
        let before = nameField.value as? String
        XCTAssertFalse(before?.isEmpty ?? true, "the editor loads the selected climb's name")

        nameField.tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 24))
        nameField.typeText("Edited Problem")
        app.buttons["climb.save"].tap()

        let selected = app.staticTexts["session.climb.selected"]
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        XCTAssertEqual(selected.label, "Edited Problem", "the rename is reflected in the quick log")
    }
}
