import XCTest

// XCUITest smoke (docs/architecture.md: the smoke set stays tiny; this Task 3 suite proves
// the app target launches and the three tabs render. Deterministic flows land with the
// M2 screens and Debug only launch argument seeding.)

final class CyberSendUISmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsThreeTabs() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Logbook"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Sessions"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)

        XCTAssertTrue(app.staticTexts["Logbook"].exists, "the logbook tab renders its title")

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Appearance"].exists, "settings shows the appearance section")
    }
}
