import XCTest

/// Organize Labels → "Use Gmail's Order": with a stored order the button is
/// enabled; pressing it puts the labels back in Gmail's order (names, case
/// ignored) and the button is disabled again.
final class LabelOrganizerOrderUITests: XCTestCase {
    private let account = "you@example.com"

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// A row's name: its label, else its value or title (the label was empty
    /// on CI once the identifier was set).
    private func name(_ e: XCUIElement) -> String {
        if !e.label.isEmpty { return e.label }
        if let v = e.value as? String, !v.isEmpty { return v }
        return e.title
    }

    /// Top-level label names of the sheet, top to bottom.
    private func topLevelNames(_ app: XCUIApplication) -> [String] {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelOrganizer.name.")).allElementsBoundByIndex
        return rows.filter { $0.exists && !name($0).contains("/") }
            .sorted { $0.frame.minY < $1.frame.minY }.map(name)
    }

    func testUseGmailsOrderRestoresTheNameOrder() {
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
        XCTAssertTrue(element("threadRow.\(account):t3", in: app).waitForExistence(timeout: 10),
                      "demo inbox should load")

        let research = element("sidebar.label.\(account).Label_research", in: app)
        XCTAssertTrue(research.waitForExistence(timeout: 10))
        research.rightClick()
        let organize = app.menuItems.matching(
            NSPredicate(format: "identifier == %@ OR title == %@", "labelMenu.organize", "Organize Labels…")).firstMatch
        XCTAssertTrue(organize.waitForExistence(timeout: 5))
        organize.click()
        let button = element("labelOrganizer.useGmailOrder", in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the sheet has Use Gmail's Order")

        // The demo mailbox stores an order for every label (its seed), so the
        // sheet starts with a stored order that is not Gmail's. A synthesized
        // drag does not start the table's drag session on CI (three tries,
        // November 2026: the list never changed), so the drag itself is
        // covered by the unit tests of `LabelOrganizerOrder`, not here.
        let names = topLevelNames(app)
        XCTAssertGreaterThan(names.count, 3)
        XCTAssertFalse(names.contains(""), "the rows' names are readable: \(names)")
        let expected = names.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertNotEqual(names, expected, "the stored order is not Gmail's")
        XCTAssertTrue(button.isEnabled, "a stored order enables the button")

        button.click()
        let deadline = Date().addingTimeInterval(5)
        while topLevelNames(app) != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(topLevelNames(app), expected, "the list is back in Gmail's order")
        XCTAssertFalse(button.isEnabled, "nothing stored: the button is disabled")
    }
}
