import XCTest

/// The search field sits in the list column's top bar, right of the view's
/// title, not in the sidebar; and the reading pane's ">>" button is gone.
/// Demo inbox.
final class ListSearchFieldUITests: XCTestCase {
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"] + extra
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

    /// Frame checks for the current layout, sidebar shown or collapsed.
    private func assertFieldInTopBar(_ app: XCUIApplication, _ when: String) {
        let field = element(app, "listSearchField")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(when): the field exists")
        let window = app.windows.firstMatch
        let row = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertLessThan(field.frame.maxY, row.frame.minY, "\(when): the field is above the list rows")
        XCTAssertLessThan(field.frame.minY - window.frame.minY, 80, "\(when): in the top bar")
        XCTAssertGreaterThanOrEqual(field.frame.minX, row.frame.minX, "\(when): inside the list column, not the sidebar")
        XCTAssertLessThanOrEqual(field.frame.maxX, window.frame.maxX, "\(when): inside the window")
        XCTAssertGreaterThanOrEqual(field.frame.width, 149, "\(when): at least the minimum width (\(field.frame))")
        XCTAssertLessThanOrEqual(field.frame.width, 381, "\(when): at most the maximum width (\(field.frame))")
        let title = app.toolbars.staticTexts["Inbox"].firstMatch
        XCTAssertTrue(title.exists, "\(when): the title shows in full")
        XCTAssertLessThanOrEqual(title.frame.maxX, field.frame.minX, "\(when): the field is right of the title")
    }

    func testFieldInTheListTopBar() {
        let app = launch(extra: ["-readingPaneHidden", "NO"])
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").waitForExistence(timeout: 10))
        // Sidebar expanded, then collapsed to the strip.
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let compose = element(app, "composeButton")
        XCTAssertTrue(compose.waitForExistence(timeout: 5), "the sidebar is shown")
        assertFieldInTopBar(app, "sidebar expanded")
        XCTAssertGreaterThan(element(app, "listSearchField").frame.minX, compose.frame.maxX,
                             "the field is right of the sidebar")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").waitForExistence(timeout: 5))
        assertFieldInTopBar(app, "sidebar collapsed")
    }

    func testSlashFocusesAndSearchFiltersTheList() {
        let app = launch(extra: ["-readingPaneHidden", "NO"])
        let t3 = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(t3.waitForExistence(timeout: 10))
        let field = element(app, "listSearchField")
        app.typeKey("/", modifierFlags: [])
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { self.hasFocus(field) }, "/ focuses the field")
        app.typeText("zzzznomatch")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitUntil { !t3.exists }, "the search filters the list")
        // Clearing restores it.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.buttons["Clear"].firstMatch.click()
        XCTAssertTrue(t3.waitForExistence(timeout: 5), "clearing brings the list back")
    }

    func testNoDoubleChevronAndPaneToggleStillWorks() {
        let app = launch(extra: ["-readingPaneHidden", "NO"])
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").waitForExistence(timeout: 10))
        let hide = app.buttons.matching(NSPredicate(format: "label == 'Hide Reading Pane'"))
        let show = app.buttons.matching(NSPredicate(format: "label == 'Show Reading Pane'"))
        XCTAssertTrue(hide.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(hide.count, 1, "only the window's toggle: no second \"Hide Reading Pane\" (>>) button")
        hide.firstMatch.click()
        XCTAssertTrue(show.firstMatch.waitForExistence(timeout: 5), "the toggle hides the pane")
        show.firstMatch.click()
        XCTAssertTrue(hide.firstMatch.waitForExistence(timeout: 5), "the toggle shows it again")
    }
}
