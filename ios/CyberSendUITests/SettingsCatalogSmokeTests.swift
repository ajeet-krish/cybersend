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

    /// US-40.2: the experimental pose flag has a visible label and a one-tap off switch in
    /// Settings, not only in the developer flags screen.
    func testExperimentalPoseFlagCanBeTurnedOffFromSettings() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CYBERSEND_UI_TEST_SEED", "1",
            "-CYBERSEND_UI_TEST_SEED_POSE", "1",
        ]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Settings"].tap()

        let toggle = app.switches["settings.pose-analysis"]
        XCTAssertTrue(reveal(toggle, in: app), "the experimental section renders while the flag is on")
        XCTAssertEqual(toggle.value as? String, "1", "the seeded launch turns the flag on")

        // The row is one accessibility element, and a tap on its centre lands on the label,
        // which does not flip a SwiftUI Toggle in a List. Tap the switch itself at the trailing
        // edge instead.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(
            app.switches["settings.pose-analysis"].waitForNonExistence(timeout: 5),
            "one tap hides the experimental section"
        )
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 6) -> Bool {
        for _ in 0..<swipes {
            if element.isHittable { return true }
            app.swipeUp()
        }
        return element.isHittable
    }
}
