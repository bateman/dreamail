import XCTest

/// Hovering a row in the demo inbox shows archive, trash, mark unread/read
/// and snooze on the right, in that order; the star sits left of the sender;
/// the row keeps its height; a click on archive removes the row.
final class ThreadRowHoverActionsUITests: XCTestCase {
    private let order = ["archive", "trash", "toggleRead", "snooze"]

    private func launch(density: String = "comfortable") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        // The short label list: a ~70-row sidebar makes every query slow.
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        // Exposes the row's buttons to the accessibility tree (off by default).
        app.launchEnvironment["DREAMAIL_UI_ROW_BUTTONS"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane",
                                "-listDensity", density]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    private func row(_ app: XCUIApplication, _ id: String = "t3") -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:\(id)").firstMatch
    }

    private func button(_ row: XCUIElement, _ id: String) -> XCUIElement {
        row.descendants(matching: .button)
            .matching(identifier: "rowAction.\(id)").firstMatch
    }

    /// One launch for the four checks. The two that only look come first;
    /// then the unselected-row check (nothing open yet, t3 still read; it
    /// marks t3 unread and trashes t4); archive last, on t3.
    func testRowActions() {
        let app = launch()
        let steps: [(String, (XCUIApplication) -> Void)] = [
            ("The star is left of the sender and always there", stepStarIsLeftOfTheSenderAndAlwaysThere),
            ("Hover shows the four actions in order and keeps the row height",
             stepHoverShowsTheFourActionsInOrderAndKeepsTheRowHeight),
            ("Actions on an unselected row leave the reading pane alone",
             stepActionsOnAnUnselectedRowLeaveTheReadingPaneAlone),
            ("Archive removes the row", stepArchiveRemovesTheRow),
        ]
        for (name, step) in steps {
            XCTContext.runActivity(named: name) { _ in step(app) }
        }
    }

    /// Compact rows: the hover actions still sit inside the row.
    func testCompactRowKeepsTheHoverActionsInside() {
        let app = launch(density: "compact")
        let row = row(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "demo inbox should load")
        let before = row.frame.height
        row.hover()
        for id in order {
            let b = button(row, id)
            XCTAssertTrue(b.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(b.frame.midY, row.frame.minY, id)
            XCTAssertLessThanOrEqual(b.frame.midY, row.frame.maxY, id)
        }
        XCTAssertEqual(row.frame.height, before, accuracy: 0.5, "hover must not change the row height")
    }

    private func stepHoverShowsTheFourActionsInOrderAndKeepsTheRowHeight(_ app: XCUIApplication) {
        let row = row(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "demo inbox should load")
        let before = row.frame.height

        row.hover()
        let buttons = order.map { button(row, $0) }
        for b in buttons { XCTAssertTrue(b.waitForExistence(timeout: 5)) }
        let xs = buttons.map(\.frame.minX)
        XCTAssertEqual(xs, xs.sorted(), "archive, trash, mark unread/read, snooze, left to right")
        XCTAssertEqual(row.frame.height, before, accuracy: 0.5, "hover must not change the row height")
    }

    private func stepStarIsLeftOfTheSenderAndAlwaysThere(_ app: XCUIApplication) {
        let row = row(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let star = row.descendants(matching: .button)
            .matching(identifier: "rowStar").firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 5), "the star shows without hovering")
        XCTAssertLessThan(star.frame.maxX, row.frame.minX + row.frame.width / 2)
    }

    private func stepArchiveRemovesTheRow(_ app: XCUIApplication) {
        let row = row(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.hover()
        let archive = button(row, "archive")
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.click()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "archiving takes the row out of the inbox")
    }

    /// A click on a button of a row that is not the selected one acts on that
    /// row only: the reading pane stays as it was (here: closed).
    private func stepActionsOnAnUnselectedRowLeaveTheReadingPaneAlone(_ app: XCUIApplication) {
        let read = row(app, "t3")      // read, and not the open conversation
        let other = row(app, "t4")     // read too
        XCTAssertTrue(read.waitForExistence(timeout: 10), "demo inbox should load")
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        // Nothing is open at launch (no conversation in the reading pane).
        let subject = app.staticTexts.matching(identifier: "threadSubject").firstMatch
        XCTAssertFalse(subject.exists, "no conversation is open at launch")
        XCTAssertTrue(read.label.hasPrefix("Read"), "t3 starts read: \(read.label)")

        read.hover()
        let toggle = button(read, "toggleRead")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertTrue(UITestWait.until { read.label.hasPrefix("Unread") },
                      "mark unread applied to the row: \(read.label)")
        XCTAssertFalse(subject.waitForExistence(timeout: 2),
                       "acting on a row must not open its conversation")

        other.hover()
        let trash = button(other, "trash")
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.click()
        XCTAssertTrue(other.waitForNonExistence(timeout: 10), "trash removed that row")
        XCTAssertTrue(read.exists, "and only that row")
        XCTAssertFalse(subject.waitForExistence(timeout: 2),
                       "the reading pane did not change")
    }
}

private enum UITestWait {
    static func until(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
