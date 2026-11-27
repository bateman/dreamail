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

    /// The text field itself (focus lives here); `listSearchBox` is its box.
    private func textField(_ app: XCUIApplication) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == 'Search'")).firstMatch
    }

    private func titleText(_ e: XCUIElement) -> String {
        (e.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? e.label
    }

    private func hasFocus(_ e: XCUIElement) -> Bool {
        (e.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    /// The field against the LIST COLUMN (its rows' x range, its bar), the title
    /// and the sidebar.
    private func assertFieldInListBar(_ app: XCUIApplication, _ when: String) {
        let field = element(app, "listSearchBox")
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
        XCTAssertEqual(titleText(title), "Inbox", "\(when): title shown in full")
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
        let box = element(app, "listSearchBox").frame
        let title = element(app, "listHeaderTitle").frame
        let icons = show.frame.insetBy(dx: -2, dy: -2)
        XCTAssertFalse(box.intersects(icons),
                       "the field does not overlap the window's toolbar buttons (field \(box), button \(show.frame))")
        XCTAssertFalse(title.intersects(icons),
                       "the title does not overlap the window's toolbar buttons (title \(title), button \(show.frame))")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").waitForExistence(timeout: 5))
        assertFieldInListBar(app, "pane hidden, sidebar collapsed")
    }

    func testSlashFocusesSearchFiltersAndEscRestores() {
        let app = launch(paneHidden: true)
        let t3 = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(t3.waitForExistence(timeout: 10))
        let field = element(app, "listSearchBox")
        app.typeKey("/", modifierFlags: [])
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { self.hasFocus(self.textField(app)) }, "/ focuses the field")
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
        XCTAssertFalse(element(app, "listSearchBox").exists, "no field beside an open conversation")
        app.typeKey("/", modifierFlags: [])
        let field = element(app, "listSearchBox")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the list is back")
        XCTAssertTrue(waitUntil { self.hasFocus(self.textField(app)) }, "/ focused the field")
    }

    func testNoDoubleChevronAndPaneToggleStillWorks() {
        let app = launch(paneHidden: false)
        let t3 = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(t3.waitForExistence(timeout: 10))
        let hide = app.buttons.matching(NSPredicate(format: "label == 'Hide Reading Pane'"))
        let show = app.buttons.matching(NSPredicate(format: "label == 'Show Reading Pane'"))
        // The toggle round trip, on the list.
        XCTAssertTrue(hide.firstMatch.waitForExistence(timeout: 5))
        hide.firstMatch.click()
        XCTAssertTrue(show.firstMatch.waitForExistence(timeout: 5), "the toggle hides the pane")
        show.firstMatch.click()
        XCTAssertTrue(hide.firstMatch.waitForExistence(timeout: 5), "the toggle shows it again")
        // A conversation open: the old ">>" lived in its toolbar. Exactly one
        // "Hide Reading Pane" control remains: the window's toggle.
        t3.click()
        XCTAssertTrue(element(app, "threadSubject").waitForExistence(timeout: 5), "a conversation is open")
        XCTAssertTrue(hide.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(hide.count, 1, "one \"Hide Reading Pane\" control only: no >> button")
    }
}
