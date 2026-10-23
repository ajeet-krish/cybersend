import XCTest

// Clip review smoke (P5): with the pose flag on, tapping a clip opens the review screen instead
// of the plain player, and the screen offers the analysis action. The analysis itself is not
// run here: the seeded clip is placeholder bytes, not a decodable movie, so Vision would fail
// and the test would be asserting on a fixture, not on the feature.

@MainActor
final class VideoReviewSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testClipOpensReviewWhenThePoseFlagIsOn() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CYBERSEND_UI_TEST_SEED", "1",
            "-CYBERSEND_UI_TEST_SEED_POSE", "1",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["session.card.open"].waitForExistence(timeout: 20))
        app.buttons["session.card.open"].tap()

        let videoRow = app.buttons["session.media.video.0"]
        XCTAssertTrue(reveal(videoRow, in: app), "the clip row is reachable")
        videoRow.tap()

        XCTAssertTrue(
            app.buttons["video.play"].waitForExistence(timeout: 10),
            "tapping the clip opens the review screen rather than the plain player"
        )
        XCTAssertTrue(
            reveal(app.buttons["video.analyze"], in: app),
            "the review screen offers analysis for a clip that has none"
        )

        app.buttons["video.done"].tap()
        XCTAssertTrue(app.buttons["session.media.video.0"].waitForExistence(timeout: 10))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 6) -> Bool {
        for _ in 0..<swipes {
            if element.isHittable { return true }
            app.swipeUp()
        }
        return element.isHittable
    }
}
