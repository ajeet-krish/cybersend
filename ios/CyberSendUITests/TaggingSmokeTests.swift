import XCTest

// Tagging smoke (docs/architecture.md test strategy, M3 US-18 and US-19): open the
// seeded bare Climb One, add the Development only synthetic photo through the identical
// ingest path, tag three holds at fixed normalized offsets on the canvas, assign start,
// intermediate, and top through the role bar, and prove the Holds list reports all
// three with roles and positions. Placement accuracy (US-18.4, at most 3 px at 1x) is
// proven by parsing the accessible position strings and mapping them back through the
// canvas fit box, comparing against the actual tap coordinates.

@MainActor
final class TaggingSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTagThreeHoldsWithRolesOnTheSyntheticPhoto() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        // 1: the Problems catalog owns climb management, so open the seeded bare Climb One
        // there, then its editor (the photo and holds sections live in the editor).
        XCTAssertTrue(app.tabBars.buttons["Problems"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Problems"].tap()
        let climbRow = app.staticTexts["Climb One"]
        XCTAssertTrue(climbRow.waitForExistence(timeout: 10), "the problems catalog lists the seeded Climb One")
        climbRow.tap()
        let editProblem = app.buttons["problem.edit"]
        XCTAssertTrue(editProblem.waitForExistence(timeout: 10), "the problem detail offers its editor")
        editProblem.tap()

        // 2: add the Development only synthetic photo (same ingest pipeline as camera
        // and library; docs/decisions.md M3 photo capture record).
        let addPhoto = app.buttons["climb.photo.add"]
        scrollIntoView(addPhoto, in: app)
        XCTAssertTrue(addPhoto.waitForExistence(timeout: 10), "the climb editor offers adding a wall photo")
        addPhoto.tap()
        let synthetic = app.buttons.matching(
            NSPredicate(format: "identifier == %@", "climb.photo.synthetic")
        ).firstMatch
        XCTAssertTrue(synthetic.waitForExistence(timeout: 10), "the development build offers the synthetic photo row")
        synthetic.tap()

        // 3: wait for ingest, then push the tagging screen.
        XCTAssertTrue(
            app.staticTexts["climb.photo.dimensions"].waitForExistence(timeout: 20),
            "the photo card renders after the synthetic ingest"
        )
        // Tagging lives only in the Holds section of the editor (the duplicate link under
        // the photo was removed in the UI overhaul).
        let tagRow = app.buttons["climb.holds.manage"]
        scrollIntoView(tagRow, in: app)
        XCTAssertTrue(tagRow.waitForExistence(timeout: 10), "the holds section links to the tagging screen")
        tagRow.tap()

        // 4: the canvas renders with the empty state hint.
        let canvas = app.images["tagging.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "the tagging screen renders the canvas")
        XCTAssertTrue(
            app.staticTexts["tagging.empty-hint"].waitForExistence(timeout: 10),
            "an empty canvas prompts for the first hold"
        )
        XCTAssertTrue(
            app.buttons["tagging.role.start"].exists,
            "the role bar renders Start, Intermediate, Top, and Unassigned"
        )

        // Fixed normalized offsets and their assigned roles, chosen well apart so a tap
        // can never land on an earlier hold (placement, not selection).
        let placements: [(x: CGFloat, y: CGFloat, role: String)] = [
            (0.25, 0.30, "start"),
            (0.50, 0.50, "intermediate"),
            (0.75, 0.70, "top"),
        ]

        let dimensions = parseDimensions(app.staticTexts["tagging.photo.dimensions"].label)
        let frame = canvas.frame
        let fit = min(frame.width / dimensions.width, frame.height / dimensions.height)
        let offsetX = (frame.width - dimensions.width * fit) / 2
        let offsetY = (frame.height - dimensions.height * fit) / 2

        for placement in placements {
            let screenX = offsetX + placement.x * dimensions.width * fit
            let screenY = offsetY + placement.y * dimensions.height * fit
            canvas.coordinate(withNormalizedOffset: CGVector(
                dx: screenX / frame.width,
                dy: screenY / frame.height
            )).tap()

            let roleButton = app.buttons["tagging.role.\(placement.role)"]
            XCTAssertTrue(roleButton.waitForExistence(timeout: 10), "a placed hold becomes the selection")
            waitUntilEnabled(roleButton, timeout: 10)
            roleButton.tap()
        }

        // 5: the canvas announces the hold count as one accessibility element.
        let announced = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Wall photo with 3 tagged holds"),
            object: canvas
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [announced], timeout: 10),
            .completed,
            "the canvas element announces the tagged hold count"
        )

        // 6: the Holds list sheet shows exactly three rows with the assigned roles.
        let holdsListButton = app.buttons["tagging.holds.list"]
        holdsListButton.tap()
        XCTAssertTrue(
            app.scrollViews["tagging.holds.sheet"].waitForExistence(timeout: 10),
            "the holds list sheet opens"
        )

        let holdRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "tagging.hold.", ".select")
        )
        XCTAssertEqual(holdRows.count, 3, "the accessibility holds list has exactly three rows")

        // 7: each row carries its role, and its reported position maps back onto the tap
        // point within the 3 px placement budget at 1x (US-18.4).
        for (index, placement) in placements.enumerated() {
            let row = app.buttons["tagging.hold.\(index).select"]
            XCTAssertTrue(row.exists, "the holds list shows hold \(index + 1)")
            XCTAssertTrue(
                row.label.contains(placement.role),
                "hold \(index + 1) carries its assigned role (\(row.label))"
            )

            let positionLabel = app.staticTexts["tagging.hold.\(index).position"].label
            guard let position = parsePosition(positionLabel) else {
                XCTFail("hold \(index + 1) position string parses: \(positionLabel)")
                continue
            }
            let placedX = offsetX + position.x * dimensions.width * fit
            let placedY = offsetY + position.y * dimensions.height * fit
            let tapX = offsetX + placement.x * dimensions.width * fit
            let tapY = offsetY + placement.y * dimensions.height * fit
            XCTAssertLessThanOrEqual(
                abs(placedX - tapX),
                3,
                "hold \(index + 1) x placement is within 3 px of the tap at 1x"
            )
            XCTAssertLessThanOrEqual(
                abs(placedY - tapY),
                3,
                "hold \(index + 1) y placement is within 3 px of the tap at 1x"
            )
        }
    }

    func testHoldDragAndLongPressDeleteConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CYBERSEND_UI_TEST_SEED", "1"]
        app.launch()

        // Reach the tagging screen on the seeded bare Climb One with a synthetic photo
        // (same setup as the tagging smoke above): catalog, detail, editor.
        XCTAssertTrue(app.tabBars.buttons["Problems"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Problems"].tap()
        let climbRow = app.staticTexts["Climb One"]
        XCTAssertTrue(climbRow.waitForExistence(timeout: 10))
        climbRow.tap()
        let editProblem = app.buttons["problem.edit"]
        XCTAssertTrue(editProblem.waitForExistence(timeout: 10))
        editProblem.tap()
        let addPhoto = app.buttons["climb.photo.add"]
        scrollIntoView(addPhoto, in: app)
        XCTAssertTrue(addPhoto.waitForExistence(timeout: 10))
        addPhoto.tap()
        let synthetic = app.buttons.matching(
            NSPredicate(format: "identifier == %@", "climb.photo.synthetic")
        ).firstMatch
        XCTAssertTrue(synthetic.waitForExistence(timeout: 10))
        synthetic.tap()
        let tagRow = app.buttons["climb.holds.manage"]
        scrollIntoView(tagRow, in: app)
        XCTAssertTrue(tagRow.waitForExistence(timeout: 15))
        tagRow.tap()

        let canvas = app.images["tagging.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        XCTAssertTrue(
            app.staticTexts["tagging.photo.dimensions"].waitForExistence(timeout: 10),
            "the tagging screen reports the working copy size for coordinate math"
        )

        let dimensions = parseDimensions(app.staticTexts["tagging.photo.dimensions"].label)
        let frame = canvas.frame
        let fit = min(frame.width / dimensions.width, frame.height / dimensions.height)
        let offsetX = (frame.width - dimensions.width * fit) / 2
        let offsetY = (frame.height - dimensions.height * fit) / 2

        func screenPoint(xNorm: CGFloat, yNorm: CGFloat) -> XCUICoordinate {
            let x = offsetX + xNorm * dimensions.width * fit
            let y = offsetY + yNorm * dimensions.height * fit
            return canvas.coordinate(withNormalizedOffset: CGVector(dx: x / frame.width, dy: y / frame.height))
        }

        // Place one hold at (0.40, 0.60): the empty hint disappears and the canvas
        // announces the single hold.
        screenPoint(xNorm: 0.40, yNorm: 0.60).tap()
        XCTAssertTrue(
            app.staticTexts["tagging.empty-hint"].waitForNonExistence(timeout: 5),
            "placing the first hold clears the empty state hint"
        )
        XCTAssertEqual(canvas.label, "Wall photo with 1 tagged holds", "one hold is placed")

        // Long press on the hold opens the delete confirmation (US-19.2), and Cancel
        // keeps the hold.
        screenPoint(xNorm: 0.40, yNorm: 0.60).press(forDuration: 1.2)
        let confirm = app.buttons.matching(
            NSPredicate(format: "identifier == %@", "tagging.delete.confirm")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8), "long press on a hold asks to confirm the delete")
        let cancel = app.buttons.matching(NSPredicate(format: "label == %@", "Cancel")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "cancel dismisses the confirmation")
        XCTAssertEqual(canvas.label, "Wall photo with 1 tagged holds", "the cancelled delete keeps the hold")

        // Drag the hold 60 points to the right (hold drag wins over the scroll pan) and
        // prove the normalized position moved by that distance in the holds list.
        let from = screenPoint(xNorm: 0.40, yNorm: 0.60)
        let to = canvas.coordinate(withNormalizedOffset: CGVector(
            dx: (offsetX + 0.40 * dimensions.width * fit + 60) / frame.width,
            dy: (offsetY + 0.60 * dimensions.height * fit) / frame.height
        ))
        from.press(forDuration: 0.4, thenDragTo: to)

        XCTAssertTrue(app.buttons["tagging.holds.list"].waitForExistence(timeout: 5))
        app.buttons["tagging.holds.list"].tap()
        let position = app.staticTexts["tagging.hold.0.position"]
        XCTAssertTrue(position.waitForExistence(timeout: 8), "the holds list shows the dragged hold")
        guard let dragged = parsePosition(position.label) else {
            XCTFail("the dragged hold position parses: \(position.label)")
            return
        }
        let movedPoints = (dragged.x - 0.40) * dimensions.width * fit
        XCTAssertGreaterThan(movedPoints, 40, "the drag moved the hold right in normalized space")
        XCTAssertLessThan(movedPoints, 80, "the drag moved roughly the requested distance")
        XCTAssertEqual(
            dragged.y,
            0.60,
            accuracy: 0.002,
            "the drag kept the vertical position (no scroll interference)"
        )
    }

    // MARK: - Helpers

    /// Swipes up until the element is on screen (bounded, so a missing element fails at
    /// the existence assertion instead of looping forever).
    /// Scrolls until the element is both present and hittable: an element that exists at
    /// the bottom edge can sit under the tab bar, where a synthesized tap lands on the bar
    /// rather than the control.
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        for _ in 0..<maxSwipes where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }

    /// Polls until the element is enabled (a placed hold must reach the role bar before
    /// the role tap can land).
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: timeout), .completed, "\(element) enables")
    }

    /// "1,200 by 1,600 pixels" into its pixel size (the label is locale formatted).
    private func parseDimensions(_ label: String) -> (width: CGFloat, height: CGFloat) {
        let parts = label.replacingOccurrences(of: ",", with: "").components(separatedBy: " ")
        guard parts.count >= 3, let width = Double(parts[0]), let height = Double(parts[2]) else {
            XCTFail("the photo dimensions string parses: \(label)")
            return (1200, 1600)
        }
        return (CGFloat(width), CGFloat(height))
    }

    /// "x 0.250, y 0.300" into its normalized point.
    private func parsePosition(_ label: String) -> (x: CGFloat, y: CGFloat)? {
        let cleaned = label
            .replacingOccurrences(of: "x ", with: "")
            .replacingOccurrences(of: "y ", with: "")
        let parts = cleaned.components(separatedBy: ",")
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces))
        else {
            return nil
        }
        return (CGFloat(x), CGFloat(y))
    }
}
