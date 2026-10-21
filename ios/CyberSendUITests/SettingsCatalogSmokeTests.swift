import XCTest

// Settings catalog smoke (M4 UI overhaul): gym and grade scheme management moved from
// rows on the Logbook home into the Settings tab, below Defaults and above Appearance.
// This suite pins the new location and proves both destinations still push, because the
// move silently breaks navigation if the SettingsRoute cases are not registered on the
// Settings stack.

@MainActor
final class SettingsCatalogSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCatalogManagementLivesInSettingsAndBothScreensPush() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Settings"].tap()

        // The rows exist in Settings and no longer sit on the Logbook home.
        XCTAssertTrue(app.buttons["settings.manage-gyms"].waitForExistence(timeout: 10), "manage gyms is a Settings row")
        XCTAssertTrue(app.buttons["settings.grade-schemes"].exists, "grade schemes is a Settings row")
        XCTAssertTrue(app.staticTexts["Appearance"].exists, "appearance still renders on the same screen")

        app.buttons["settings.manage-gyms"].tap()
        XCTAssertTrue(app.buttons["gyms.create"].waitForExistence(timeout: 10), "manage gyms pushes the gyms screen")

        app.navigationBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.grade-schemes"].waitForExistence(timeout: 10), "back returns to Settings")

        app.buttons["settings.grade-schemes"].tap()
        XCTAssertTrue(app.buttons["grades.create"].waitForExistence(timeout: 10), "grade schemes pushes the grades screen")

        app.tabBars.buttons["Logbook"].tap()
        XCTAssertFalse(app.buttons["logbook.manage-gyms"].exists, "manage gyms left the Logbook home")
        XCTAssertFalse(app.buttons["logbook.grade-schemes"].exists, "grade schemes left the Logbook home")
    }
}
