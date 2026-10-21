import XCTest

// XCUITest smoke (docs/architecture.md: the smoke set stays tiny; this Task 3 suite proves
// the app target launches and every tab renders. M3 Task 5 adds the Stats tab between
// Logbook and Sessions (US-23), so the tab bar now carries four tabs matching the frozen
// TypeScript spec app/(tabs)/_layout.tsx.)

@MainActor
final class CyberSendUISmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsFourTabs() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Logbook"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Stats"].exists, "the stats tab sits between Logbook and Sessions (US-23)")
        XCTAssertTrue(app.tabBars.buttons["Sessions"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)

        XCTAssertTrue(app.staticTexts["Logbook"].exists, "the logbook tab renders its title")

        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(app.staticTexts["Stats"].exists, "the stats tab renders its title")

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Appearance"].exists, "settings shows the appearance section")
    }
}
