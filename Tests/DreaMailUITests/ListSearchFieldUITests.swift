import XCTest

/// The search field is a toolbar item of the list column (`listSearchBox`),
/// right of the view's title, not in the sidebar; the mouse reaches it; the
/// toolbar never overflows at the window's minimum size; and the reading
/// pane's ">>" button is gone. Demo inbox.
final class ListSearchFieldUITests: XCTestCase {
    /// `paneHidden: nil` passes no `-readingPaneHidden`: a launch argument sits in
    /// the defaults' argument domain and overrides what the toggle writes.
    private func launch(paneHidden: Bool?, openStyle: String = "readingPane") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", openStyle]
        if let paneHidden { app.launchArguments += ["-readingPaneHidden", paneHidden ? "YES" : "NO"] }
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

    private func hasFocus(_ e: XCUIElement) -> Bool {
        (e.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    /// The view's title in the toolbar (a static text in the top band).
    private func titleElement(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.windows.firstMatch.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", text, text))
            .allElementsBoundByIndex.first { $0.exists && $0.frame.minY < 100 }
            ?? app.windows.firstMatch.staticTexts[text]
    }

    private static var dumpedToolbar = false

    /// What the toolbar really holds, and that it is all there. Asserted
    /// positively: the field, the pane toggle and the focus button exist and
    /// are hittable (so nothing was clipped into an overflow menu), also
    /// "Search all of Gmail" while a search is committed, and Ask AI where the
    /// build shows it. Prints the toolbar once and the field's width.
    private func assertToolbarIntact(_ app: XCUIApplication, _ when: String, searching: Bool = false) {
        let box = element(app, "listSearchBox")
        XCTAssertTrue(box.waitForExistence(timeout: 5), "\(when): the field exists")
        if !Self.dumpedToolbar {
            Self.dumpedToolbar = true
            let all = app.toolbars.descendants(matching: .any).allElementsBoundByIndex
                .filter { $0.exists }
                .map { "\($0.elementType.rawValue)|\($0.identifier)|\($0.label)|\($0.frame)" }
            print("ListSearchField toolbar dump: \(all)")
        }
        let window = app.windows.firstMatch
        print("ListSearchField [\(when)]: window \(window.frame), field \(box.frame) (width \(box.frame.width))")
        XCTAssertTrue(box.isHittable, "\(when): the field is hittable (\(box.frame))")
        XCTAssertGreaterThanOrEqual(box.frame.width, ListHeaderMetrics.minWidth - 1,
                                    "\(when): the field is at least its minimum (\(box.frame))")
        let toggle = app.toolbars.buttons.matching(NSPredicate(format: "label ENDSWITH 'Reading Pane'")).firstMatch
        XCTAssertTrue(toggle.exists && toggle.isHittable, "\(when): the pane toggle is in the toolbar and hittable")
        let focus = app.toolbars.buttons.matching(NSPredicate(format: "label == 'Focus Conversation' OR label == 'Exit Focus'")).firstMatch
        XCTAssertTrue(focus.exists && focus.isHittable, "\(when): the focus button is in the toolbar and hittable")
        if searching {
            let all = app.toolbars.buttons.matching(NSPredicate(format: "label CONTAINS 'Search all of Gmail' OR label CONTAINS 'Searching'")).firstMatch
            XCTAssertTrue(all.exists && all.isHittable, "\(when): \"Search all of Gmail\" is in the toolbar and hittable")
        }
        let askAI = app.toolbars.buttons["Ask AI"]
        if askAI.exists { XCTAssertTrue(askAI.isHittable, "\(when): Ask AI is hittable") }
    }

    /// The field against the LIST COLUMN (its rows' x range), the title and the sidebar.
    private func assertFieldInListBar(_ app: XCUIApplication, _ when: String) {
        let field = element(app, "listSearchBox")
        let row = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(when): the field exists")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let column = row.frame   // the list column's x range
        XCTAssertGreaterThanOrEqual(field.frame.minX, column.minX, "\(when): not left of the list column (\(field.frame) vs \(column))")
        XCTAssertLessThanOrEqual(field.frame.maxX, app.windows.firstMatch.frame.maxX, "\(when): inside the window")
        XCTAssertLessThan(field.frame.maxY, row.frame.minY, "\(when): above the list rows")
        let title = titleElement(app, "Inbox")
        XCTAssertTrue(title.exists, "\(when): the title is shown")
        XCTAssertLessThanOrEqual(title.frame.maxX, field.frame.minX, "\(when): the field is right of the title (title \(title.frame), field \(field.frame))")
        XCTAssertGreaterThanOrEqual(field.frame.width, ListHeaderMetrics.minWidth - 1, "\(when): at least the minimum (\(field.frame))")
        XCTAssertLessThanOrEqual(field.frame.width, ListHeaderMetrics.maxWidth + 1, "\(when): at most the maximum (\(field.frame))")
        let sidebarRow = element(app, "sidebar.inbox")
        if sidebarRow.exists {
            XCTAssertGreaterThan(field.frame.minX, sidebarRow.frame.maxX, "\(when): right of the sidebar")
        }
        assertToolbarIntact(app, when)
    }

    /// A real toolbar item takes the mouse: a click focuses the field, it
    /// takes typing, its clear button appears and works, and the window does
    /// not move.
    private func assertMouseReach(_ app: XCUIApplication, _ when: String) {
        let window = app.windows.firstMatch
        let before = window.frame
        let text = textField(app)
        XCTAssertTrue(text.waitForExistence(timeout: 5), "\(when): text field")
        text.click()
        XCTAssertTrue(waitUntil { self.hasFocus(text) }, "\(when): a click focuses the field")
        app.typeText("ab")
        XCTAssertTrue(waitUntil { ((text.value as? String) ?? "") == "ab" }, "\(when): it accepts typing (\(String(describing: text.value)))")
        let clear = element(app, "listSearchBox").buttons["Clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "\(when): the clear button appears")
        clear.click()
        XCTAssertTrue(waitUntil { ((text.value as? String) ?? "x").isEmpty }, "\(when): the clear button clears")
        XCTAssertEqual(window.frame, before, "\(when): the window did not move or resize")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    /// Drags the window's bottom-right corner by `dx`: far to the left the
    /// window stops at its minimum size; to the right it grows.
    private func dragCorner(_ app: XCUIApplication, dx: CGFloat) {
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        let target = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: dx, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: target)
    }

    private func shrinkToMinimum(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        dragCorner(app, dx: -700)
        XCTAssertTrue(waitUntil(timeout: 8) { window.frame.width <= 970 },
                      "the window shrank to its minimum width (now \(window.frame))")
    }

    func testFieldInTheListBar_paneOpen() {
        let app = launch(paneHidden: false)
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "composeButton").waitForExistence(timeout: 5), "sidebar shown")
        assertFieldInListBar(app, "pane open, sidebar expanded")
        assertMouseReach(app, "pane open, sidebar expanded")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").waitForExistence(timeout: 5))
        assertFieldInListBar(app, "pane open, sidebar collapsed")
        assertMouseReach(app, "pane open, sidebar collapsed")
    }

    func testFieldInTheListBar_paneHidden() {
        let app = launch(paneHidden: true)
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "composeButton").waitForExistence(timeout: 5))
        assertFieldInListBar(app, "pane hidden, sidebar expanded")
        assertMouseReach(app, "pane hidden, sidebar expanded")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").waitForExistence(timeout: 5))
        assertFieldInListBar(app, "pane hidden, sidebar collapsed")
        assertMouseReach(app, "pane hidden, sidebar collapsed")
    }

    /// At the window's minimum size, in the sidebar states the app has
    /// (expanded, strip): no overflow chevron and the field is hittable, with
    /// the pane open and hidden.
    func testNoOverflowAtTheMinimumWindow() {
        let app = launch(paneHidden: false)
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").waitForExistence(timeout: 10))
        shrinkToMinimum(app)
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "composeButton").waitForExistence(timeout: 5))
        assertToolbarIntact(app, "minimum window, sidebar expanded")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").waitForExistence(timeout: 5))
        assertToolbarIntact(app, "minimum window, sidebar collapsed")
        // A search in progress adds "Search all of Gmail" to the bar.
        app.typeKey("/", modifierFlags: [])
        XCTAssertTrue(waitUntil { self.hasFocus(self.textField(app)) })
        app.typeText("zzzznomatch")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitUntil { !self.element(app, "threadRow.you@example.com:t3").exists }, "the search is committed")
        assertToolbarIntact(app, "minimum window, searching", searching: true)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
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
        // The suggestions panel hangs under the field, at the column's trailing
        // edge (the field's side), inside the column.
        let panel = element(app, "searchResultsPanel")
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "the results panel opens")
        print("ListSearchField panel \(panel.frame), field \(field.frame)")
        XCTAssertGreaterThanOrEqual(panel.frame.minY, field.frame.maxY - 1, "panel below the field")
        XCTAssertEqual(panel.frame.maxX, field.frame.maxX, accuracy: 24, "panel ends where the field ends")
        XCTAssertGreaterThanOrEqual(panel.frame.minX, t3.frame.minX - 1, "panel inside the list column")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitUntil { !t3.exists }, "the search filters the list")
        // Return committed the search and left the field: Esc drops it.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(t3.waitForExistence(timeout: 5), "Esc restores the full list")
    }

    /// Compact layout (below 1080 pt; the window is shrunk to its minimum so
    /// the test always runs it): with a conversation open there is no list,
    /// `/` goes back to it and focuses (the pending focus on mount).
    func testSlashFromAConversationInTheCompactLayout() {
        let app = launch(paneHidden: false)
        let t3 = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(t3.waitForExistence(timeout: 10))
        shrinkToMinimum(app)
        XCTAssertTrue(t3.waitForExistence(timeout: 5))
        t3.click()
        XCTAssertTrue(app.buttons["compactBackButton"].waitForExistence(timeout: 5), "a conversation is open")
        XCTAssertFalse(element(app, "listSearchBox").exists, "no field beside an open conversation")
        app.typeKey("/", modifierFlags: [])
        let field = element(app, "listSearchBox")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the list is back")
        XCTAssertTrue(waitUntil { self.hasFocus(self.textField(app)) }, "/ focused the field")
    }

    /// A conversation filling the window (full-window style): `/` leaves it and
    /// focuses the field, as it does in the compact layout.
    func testSlashFromAFullWindowConversation() {
        let app = launch(paneHidden: nil, openStyle: "fullWindow")
        let t3 = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(t3.waitForExistence(timeout: 10), "the list")
        t3.click()
        XCTAssertTrue(app.buttons["exitFocusButton"].waitForExistence(timeout: 5), "a conversation fills the window")
        app.typeKey("/", modifierFlags: [])
        XCTAssertTrue(waitUntil { !app.buttons["exitFocusButton"].exists }, "/ left the conversation")
        XCTAssertTrue(element(app, "listSearchBox").waitForExistence(timeout: 5), "the list is back")
        XCTAssertTrue(waitUntil { self.hasFocus(self.textField(app)) }, "/ focused the field")
    }

    func testNoDoubleChevronAndPaneToggleStillWorks() {
        let app = launch(paneHidden: nil)
        let t3 = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(t3.waitForExistence(timeout: 10))
        let hide = app.buttons.matching(NSPredicate(format: "label == 'Hide Reading Pane'"))
        let show = app.buttons.matching(NSPredicate(format: "label == 'Show Reading Pane'"))
        // The toggle round trip on the list, from whichever state the defaults hold.
        XCTAssertTrue(waitUntil { hide.firstMatch.exists || show.firstMatch.exists }, "the toggle exists")
        let startedOpen = hide.firstMatch.exists
        (startedOpen ? hide : show).firstMatch.click()
        XCTAssertTrue((startedOpen ? show : hide).firstMatch.waitForExistence(timeout: 5),
                      "the toggle flips the pane")
        (startedOpen ? show : hide).firstMatch.click()
        XCTAssertTrue((startedOpen ? hide : show).firstMatch.waitForExistence(timeout: 5),
                      "the toggle flips it back")
        // Make sure the pane is open. Showing it with a thread selected opens
        // that conversation, and at this window width that replaces the list.
        if show.firstMatch.exists { show.firstMatch.click() }
        XCTAssertTrue(hide.firstMatch.waitForExistence(timeout: 5))
        // A conversation open: the old ">>" lived in its toolbar. Exactly one
        // "Hide Reading Pane" control remains: the window's toggle.
        if !element(app, "threadSubject").exists {
            XCTAssertTrue(t3.waitForExistence(timeout: 10), "the list is there to open a conversation from")
            t3.click()
        }
        XCTAssertTrue(element(app, "threadSubject").waitForExistence(timeout: 5), "a conversation is open")
        XCTAssertTrue(hide.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(hide.count, 1, "one \"Hide Reading Pane\" control only: no >> button")
    }
}

/// The field's sizes, as the test sees them (kept equal to `ListHeaderLayout`).
private enum ListHeaderMetrics {
    static let minWidth: CGFloat = 140
    static let maxWidth: CGFloat = 380
}
