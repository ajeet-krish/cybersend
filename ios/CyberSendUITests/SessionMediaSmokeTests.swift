import XCTest

// Session media smoke (UI overhaul): an open session shows its seeded photo and clip, the
// clip row reports its duration, tapping either presents the right surface, and the media
// block is reachable on an old session too. The library pickers themselves are system UI and
// stay untested by design (docs/architecture.md test strategy).

@MainActor
final class SessionMediaSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSessionShowsPhotoAndClipAndPresentsPlayback() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        XCTAssertTrue(app.buttons["session.card.open"].waitForExistence(timeout: 20))
        app.buttons["session.card.open"].tap()

        // Media sits under the quick log controls on a live session, so reveal it first.
        let photo = app.buttons["session.media.photo.0"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "the session photo strip renders the seeded photo")
        XCTAssertTrue(reveal(photo, in: app), "the photo strip scrolls into view")
        XCTAssertTrue(reveal(app.buttons["session.media.add-photo"], in: app), "the library photo import is offered")
        XCTAssertTrue(reveal(app.buttons["session.media.add-video"], in: app), "the library video import is offered")

        let duration = app.staticTexts["session.media.video.0.duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 10), "the clip row renders its duration")
        XCTAssertEqual(duration.label, "0:12")

        // Playback presents a player sheet with the clip title and a way out.
        let videoRow = app.buttons["session.media.video.0"]
        XCTAssertTrue(reveal(videoRow, in: app))
        videoRow.tap()
        XCTAssertTrue(app.buttons["media.player.done"].waitForExistence(timeout: 10), "tapping the clip presents the player")
        XCTAssertTrue(app.navigationBars["Clip 1"].exists)
        app.buttons["media.player.done"].tap()

        // The photo opens full size with a delete action behind a confirmation.
        XCTAssertTrue(reveal(photo, in: app))
        photo.tap()
        XCTAssertTrue(
            app.buttons["session.media.photo.delete"].waitForExistence(timeout: 10),
            "the full size preview offers delete"
        )
    }

    /// Scrolls until the element is hittable. The session screen is one scroll view and media
    /// lives below the quick log controls on a live session.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 5) -> Bool {
        for _ in 0..<swipes {
            if element.isHittable { return true }
            app.swipeUp()
        }
        return element.isHittable
    }

    func testClosedSessionAlsoShowsMedia() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        // The Sessions tab lists the closed seeded sessions; open the newest closed one.
        XCTAssertTrue(app.tabBars.buttons["Sessions"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Sessions"].tap()

        let closed = app.buttons["history.row.1"]
        XCTAssertTrue(closed.waitForExistence(timeout: 10), "the seeded closed session is listed")
        closed.tap()

        XCTAssertTrue(
            app.buttons["session.media.add-photo"].waitForExistence(timeout: 10),
            "media is available on a closed session, which is what makes it retroactive"
        )
        XCTAssertTrue(app.buttons["session.media.add-video"].exists)
    }
}
