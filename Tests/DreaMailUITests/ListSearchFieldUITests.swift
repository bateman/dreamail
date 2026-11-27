import XCTest

/// The search field sits in the list column's top bar, right
/// of the view's title, not in the sidebar; and the reading pane's ">>" button
/// is gone. Demo inbox.
final class ListSearchFieldUITests: XCTestCase {
    private func launch(paneHidden: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-readingPaneHidden", paneHidden ? "YES" : "NO",
                                "-threadOpenStyle", "readingPane"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    private func hasFocus(_ e: XCUIElement) -> Bool {
        (e.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    /// The field against the LIST COLUMN (its rows' x range, its bar), the title
    /// and the sidebar.
    private func assertFieldInListBar(_ app: XCUIApplication, _ when: String) {
        let field = element(app, "listSearchField")
        let title = element(app, "listHeaderTitle")
        let row = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(when): the field exists")
        XCTAssertTrue(title.exists, "\(when): the title exists")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let column = row.frame   // the list column's x range
        XCTAssertGreaterThanOrEqual(field.frame.minX, column.minX, "\(when): not left of the list column (\(field.frame) vs \(column))")
        XCTAssertLessThanOrEqual(field.frame.maxX, column.maxX + 1, "\(when): not right of the list column")
        XCTAssertLessThan(field.frame.maxY, row.frame.minY, "\(when): above the list rows")
        XCTAssertGreaterThanOrEqual(title.frame.minX, column.minX, "\(when): title inside the column")
        XCTAssertLessThanOrEqual(title.frame.maxX, field.frame.minX, "\(when): field right of the title")
        XCTAssertEqual(title.frame.midY, field.frame.midY, accuracy: 12, "\(when): same bar")
        XCTAssertEqual(title.label, "Inbox", "\(when): title shown in full")
        XCTAssertGreaterThanOrEqual(field.frame.width, 149, "\(when): at least the minimum (\(field.frame))")
        XCTAssertLessThanOrEqual(field.frame.width, 381, "\(when): at most the maximum (\(field.frame))")
        // Not in the sidebar: the sidebar's rows are all left of the field.
        let sidebarRow = element(app, "sidebar.inbox")
        if sidebarRow.exists {
            XCTAssertGreaterThan(field.frame.minX, sidebarRow.frame.maxX, "\(when): right of the sidebar")
        }
    }

    func testFieldInTheListBar_paneOpen() {
        let app = launch(paneHidden: false)
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "composeButton").waitForExistence(timeout: 5), "sidebar shown")
        assertFieldInListBar(app, "sidebar expanded")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").waitForExistence(timeout: 5))
        assertFieldInListBar(app, "sidebar collapsed")
    }

    /// The list is the window's last column: the field stays clear of the
    /// window's own toolbar buttons.
    func testFieldInTheListBar_paneHidden() {
        let app = launch(paneHidden: true)
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "composeButton").waitForExistence(timeout: 5))
        assertFieldInListBar(app, "pane hidden, sidebar expanded")
        let show = app.buttons.matching(NSPredicate(format: "label == 'Show Reading Pane'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(element(app, "listSearchField").frame.maxX, show.frame.minX,
                                 "the field is left of the window's toolbar buttons")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").waitForExistence(timeout: 5))
        assertFieldInListBar(app, "pane hidden, sidebar collapsed")
    }

    func testSlashFocusesSearchFiltersAndEscRestores() {
        let app = launch(paneHidden: true)
        let t3 = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(t3.waitForExistence(timeout: 10))
        let field = element(app, "listSearchField")
        app.typeKey("/", modifierFlags: [])
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { self.hasFocus(field) }, "/ focuses the field")
        app.typeText("zzzznomatch")
        // The suggestions panel hangs under the field, same trailing edge, inside the column.
        let panel = element(app, "searchResultsPanel")
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "the results panel opens")
        XCTAssertGreaterThanOrEqual(panel.frame.minY, field.frame.maxY - 1, "panel below the field")
        XCTAssertEqual(panel.frame.maxX, field.frame.maxX, accuracy: 2, "panel ends where the field ends")
        XCTAssertGreaterThanOrEqual(panel.frame.minX, t3.frame.minX - 1, "panel inside the list column")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitUntil { !t3.exists }, "the search filters the list")
        // Return committed the search and left the field: Esc drops it.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(t3.waitForExistence(timeout: 5), "Esc restores the full list")
    }

    /// Compact layout (the default window is narrower than three panes): with a
    /// conversation open there is no list, `/` goes back to it and focuses.
    func testSlashFromAConversationInTheCompactLayout() throws {
        let app = launch(paneHidden: false)
        let t3 = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(t3.waitForExistence(timeout: 10))
        try XCTSkipIf(app.windows.firstMatch.frame.width >= 1080,
                      "window is wide enough for three panes: no compact layout here")
        t3.click()
        XCTAssertTrue(app.buttons["compactBackButton"].waitForExistence(timeout: 5), "a conversation is open")
        XCTAssertFalse(element(app, "listSearchField").exists, "no field beside an open conversation")
        app.typeKey("/", modifierFlags: [])
        let field = element(app, "listSearchField")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the list is back")
        XCTAssertTrue(waitUntil { self.hasFocus(field) }, "/ focused the field")
    }

    func testNoDoubleChevronAndPaneToggleStillWorks() {
        let app = launch(paneHidden: false)
        let t3 = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(t3.waitForExistence(timeout: 10))
        t3.click()   // a conversation open: the old ">>" lived in its toolbar
        let hide = app.buttons.matching(NSPredicate(format: "label == 'Hide Reading Pane'"))
        let show = app.buttons.matching(NSPredicate(format: "label == 'Show Reading Pane'"))
        // Compact windows have no pane toggle target to hide; the toggle is
        // still in the window toolbar.
        XCTAssertTrue(hide.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(hide.count, 1, "one \"Hide Reading Pane\" control only: no >> button")
        hide.firstMatch.click()
        XCTAssertTrue(show.firstMatch.waitForExistence(timeout: 5), "the toggle hides the pane")
        XCTAssertEqual(show.count, 1)
        show.firstMatch.click()
        XCTAssertTrue(hide.firstMatch.waitForExistence(timeout: 5), "the toggle shows it again")
    }
}
