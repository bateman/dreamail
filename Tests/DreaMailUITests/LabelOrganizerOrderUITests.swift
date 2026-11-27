import XCTest

/// Organize Labels → "Use Gmail's Order": after a drag the button is enabled;
/// pressing it puts the labels back in Gmail's order (names, case ignored)
/// and the button is disabled again.
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

    func testUseGmailsOrderRestoresTheNameOrderAfterADrag() {
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

        // Drag the first label to the bottom: an order is stored.
        let names = topLevelNames(app)
        XCTAssertGreaterThan(names.count, 3)
        XCTAssertFalse(names.contains(""), "the rows' names are readable: \(names)")
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelOrganizer.name."))
            // Only rows on screen: the sheet is shorter than the list, and a
            // row below its edge is "not hittable" (CI, November 2026).
            .allElementsBoundByIndex.filter { !name($0).contains("/") && $0.isHittable }
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertGreaterThan(rows.count, 2, "some top-level rows are on screen")
        let first = rows[0]
        let last = rows[rows.count - 1]
        first.press(forDuration: 0.5, thenDragTo: last)
        var dragged = topLevelNames(app)
        let moved = Date().addingTimeInterval(3)
        while dragged == names, Date() < moved {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            dragged = topLevelNames(app)
        }
        XCTAssertNotEqual(dragged, names, "the drag moved a label")
        XCTAssertTrue(button.isEnabled, "a stored order enables the button")
        let expected = names.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertNotEqual(dragged, expected, "after the drag the list is not in Gmail's order")

        button.click()
        let deadline = Date().addingTimeInterval(5)
        while topLevelNames(app) != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(topLevelNames(app), expected, "the list is back in Gmail's order")
        XCTAssertFalse(button.isEnabled, "nothing stored: the button is disabled")
    }
}
