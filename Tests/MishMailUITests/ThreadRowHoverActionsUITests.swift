import XCTest

/// Hovering a row in the demo inbox shows archive, trash, mark unread/read
/// and snooze on the right, in that order; the star sits left of the sender;
/// the row keeps its height; a click on archive removes the row.
final class ThreadRowHoverActionsUITests: XCTestCase {
    private let rowId = "threadRow.you@example.com:t3"
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

    private func row(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: rowId).firstMatch
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
        XCTAssertLessThan(star.frame.minX, button(row, "archive").frame.minX)
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
}
