import XCTest

/// A sheet opened from the sidebar owns the keyboard: Escape closes it and
/// the single-key shortcuts ("e" archives, "#" deletes) typed in its text
/// field do not reach the selected conversation behind it.
final class SidebarSheetEscapeUITests: XCTestCase {
    private let account = "you@example.com"

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    private func rowIds(_ app: XCUIApplication) -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'threadRow.'"))
            .allElementsBoundByIndex.map(\.identifier).sorted()
    }

    func testNewLabelSheetKeepsShortcutsAndEscapeCloses() {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane",
                                "-keyBindings", "",
                                "-sidebar.labels.expanded.\(account)", "()"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        // Sidebar starts collapsed; → reveals it (see SidebarNavUITests).
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])

        // A conversation is selected: "e" or "#" would archive or delete it.
        let row = element("threadRow.\(account):t3", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(app.staticTexts.matching(identifier: "threadSubject").firstMatch
            .waitForExistence(timeout: 5), "the conversation is open")

        let before = rowIds(app)
        XCTAssertFalse(before.isEmpty)
        let add = element("sidebar.labels.add", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        // The identifier lands on the whole "Labels" header row (UI test
        // log, November 2026), whose centre is blank: click the "+" at its
        // trailing end.
        add.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).click()
        let field = element("newLabel.name", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the + opens the new label sheet")
        field.click()
        // Shortcut keys, and Escape's own ladder (reading pane, selection).
        field.typeText("e#j")
        XCTAssertEqual(field.value as? String, "e#j", "the keys went into the field")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForAbsence(field), "Escape closes the new label sheet")
        // Nothing the keys stand for ("e" archive, "#" delete, "j" next)
        // happened to the list.
        XCTAssertEqual(rowIds(app), before, "typing in the sheet left the list alone")
        XCTAssertTrue(app.staticTexts.matching(identifier: "threadSubject").firstMatch.exists,
                      "Escape closed the sheet only, not the open conversation")

        // Organize Labels has only "Done" as its default action: Escape
        // closes it too, and the mailbox behind it is left alone.
        let research = element("sidebar.label.\(account).Label_research", in: app)
        XCTAssertTrue(research.waitForExistence(timeout: 5))
        research.rightClick()
        let organize = app.menuItems.matching(
            NSPredicate(format: "identifier == %@ OR title == %@", "labelMenu.organize", "Organize Labels…")).firstMatch
        XCTAssertTrue(organize.waitForExistence(timeout: 5), "the label menu has Organize Labels")
        organize.click()
        let title = app.staticTexts["Organize Labels"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Organize Labels is up")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForAbsence(title), "Escape closes Organize Labels")
        XCTAssertEqual(rowIds(app), before, "Organize Labels left the list alone")
        XCTAssertTrue(app.staticTexts.matching(identifier: "threadSubject").firstMatch.exists,
                      "Escape closed the dialog only, not the open conversation")
    }
}
