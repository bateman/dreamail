import XCTest

/// Hovering a row in the demo inbox shows archive, trash, mark unread/read
/// and snooze on the right, in that order; the star sits left of the sender;
/// the row keeps its height; a click on archive removes the row.
final class ThreadRowHoverActionsUITests: XCTestCase {
    private let order = ["archive", "trash", "toggleRead", "snooze"]

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        // Exposes the row's buttons to the accessibility tree (off by default).
        app.launchEnvironment["MISHMAIL_UI_ROW_BUTTONS"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"]
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

    func testHoverShowsTheFourActionsInOrderAndKeepsTheRowHeight() {
        let app = launch()
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

    func testStarIsLeftOfTheSenderAndAlwaysThere() {
        let app = launch()
        let row = row(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let star = row.descendants(matching: .button)
            .matching(identifier: "rowStar").firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 5), "the star shows without hovering")
        XCTAssertLessThan(star.frame.maxX, row.frame.minX + row.frame.width / 2)
    }

    func testArchiveRemovesTheRow() {
        let app = launch()
        let row = row(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.hover()
        let archive = button(row, "archive")
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.click()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "archiving takes the row out of the inbox")
    }

    /// A click on a button of a row that is not the selected one acts on that
    /// row only: the reading pane keeps the open conversation.
    func testActionsOnAnUnselectedRowLeaveTheReadingPaneAlone() {
        let app = launch()
        let read = row(app, "t3")      // read, not the pre-selected top row
        let other = row(app, "t4")     // read too
        XCTAssertTrue(read.waitForExistence(timeout: 10), "demo inbox should load")
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        let subject = app.staticTexts.matching(identifier: "threadSubject").firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 10), "the reading pane shows a conversation")
        let open = subject.label
        XCTAssertFalse(open.contains("CI passed"), "t3 is not the open conversation")
        XCTAssertTrue(read.label.hasPrefix("Read"), "t3 starts read: \(read.label)")

        read.hover()
        let toggle = button(read, "toggleRead")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertTrue(UITestWait.until { read.label.hasPrefix("Unread") },
                      "mark unread applied to the row: \(read.label)")
        XCTAssertEqual(subject.label, open, "the reading pane did not change")

        other.hover()
        let trash = button(other, "trash")
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.click()
        XCTAssertTrue(other.waitForNonExistence(timeout: 10), "trash removed that row")
        XCTAssertTrue(read.exists, "and only that row")
        XCTAssertEqual(subject.label, open, "the reading pane did not change")
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
