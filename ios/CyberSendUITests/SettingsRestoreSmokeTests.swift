import XCTest

// Settings restore smoke (docs/architecture.md test strategy: the smoke set covers
// settings with restore confirmation; docs/reviews.md M1 review obligation: no path may
// call restoreBackup without an explicit confirmation dialog). The Debug only seed writes
// one local backup and then renames the gym, so the two paths are distinguishable:
// confirming reverts to the archived name and dismissing leaves the rename in place,
// proving the cancel path changes nothing. The settings List renders lazily, so the
// restore rows are scrolled into view first; scrolling is not a tap and this suite has no
// tap budget. On the iOS 26 simulator the confirmation dialog presents as a popover
// sheet that carries only the destructive button; dismissing it (tap outside) runs the
// cancel path through the isPresented binding.

@MainActor
final class SettingsRestoreSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()
        return app
    }

    /// Swipes up until the element is on screen (bounded, so a missing element fails at
    /// the existence assertion instead of looping forever).
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 10) {
        for _ in 0..<maxSwipes where !element.exists {
            app.swipeUp()
        }
    }

    /// The dialog buttons render twice in the accessibility tree on the iOS 26
    /// simulator, so queries always resolve to the first match.
    private func dialogButton(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    /// Opens the destructive restore confirmation dialog from the settings tab and
    /// returns the confirm button.
    private func openRestoreDialog(_ app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Settings"].tap()

        let restore = app.buttons["settings.restore"]
        scrollIntoView(restore, in: app)
        XCTAssertTrue(restore.waitForExistence(timeout: 10), "settings lists the restore entry point")
        restore.tap()

        let confirm = dialogButton(app, identifier: "settings.restore.confirm")
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 10),
            "restore is gated behind an explicit destructive confirmation dialog"
        )
        XCTAssertTrue(
            confirm.label.contains("Restore"),
            "the destructive dialog action names the restore"
        )
        return confirm
    }

    func testRestoreIsGatedBehindAConfirmationDialogAndCancelChangesNothing() throws {
        let app = launchSeededApp()

        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Settings"].tap()

        let lastBackup = app.staticTexts["settings.last-backup"]
        scrollIntoView(lastBackup, in: app)
        XCTAssertTrue(lastBackup.exists, "the seeded backup shows a last backup stamp")
        XCTAssertTrue(lastBackup.label.contains("Last backup"), "the stamp names the seeded backup time")

        let confirm = openRestoreDialog(app)

        // Cancel path: dismiss the dialog without confirming (tap outside the popover,
        // which flips the isPresented binding back and runs gate.cancel()).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        XCTAssertTrue(
            confirm.waitForNonExistence(timeout: 10),
            "dismissing the dialog does not restore"
        )

        // Cancel path leaves the data unchanged: the post backup rename is still here.
        XCTAssertTrue(app.tabBars.buttons["Sessions"].exists)
        app.tabBars.buttons["Sessions"].tap()
        let gymRow = app.staticTexts["history.row.0.gym"]
        XCTAssertTrue(gymRow.waitForExistence(timeout: 10))
        XCTAssertTrue(
            gymRow.label.contains("Boulder Lab Renamed"),
            "the cancelled restore leaves the post backup rename untouched"
        )
    }

    func testConfirmedRestoreRevertsToTheNewestBackup() throws {
        let app = launchSeededApp()
        let confirm = openRestoreDialog(app)
        confirm.tap()

        // The restore runs and reports through the import summary alert (US-16 counts).
        let done = dialogButton(app, identifier: "settings.report.dismiss")
        XCTAssertTrue(done.waitForExistence(timeout: 30), "a confirmed restore shows the import report summary")
        done.tap()

        // Confirmed path replaced the data with the backup: the rename is reverted.
        XCTAssertTrue(app.tabBars.buttons["Sessions"].exists)
        app.tabBars.buttons["Sessions"].tap()
        let gymRow = app.staticTexts["history.row.0.gym"]
        XCTAssertTrue(gymRow.waitForExistence(timeout: 10))
        XCTAssertEqual(
            gymRow.label,
            "Boulder Lab",
            "the confirmed restore reverts the gym name to the archived backup content"
        )
        XCTAssertTrue(
            app.staticTexts["history.row.1.attempts"].label.contains("4"),
            "the restored history keeps its attempt counts"
        )
    }
}
