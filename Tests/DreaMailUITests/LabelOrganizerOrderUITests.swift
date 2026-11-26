import XCTest

/// Organize Labels → "Use Gmail's Order": after a drag the button is enabled;
/// pressing it puts the labels back in Gmail's order (names, case ignored)
/// and the button is disabled again.
final class LabelOrganizerOrderUITests: XCTestCase {
    private let account = "you@example.com"

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Top-level label names of the sheet, top to bottom.
    private func topLevelNames(_ app: XCUIApplication) -> [String] {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelOrganizer.name.")).allElementsBoundByIndex
        return rows.filter { $0.exists && !$0.label.contains("/") }
            .sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
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
        let first = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "labelOrganizer.name.", names[0])).firstMatch
        let last = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "labelOrganizer.name.", names[names.count - 1])).firstMatch
        first.press(forDuration: 0.5, thenDragTo: last)
        XCTAssertTrue(button.isEnabled, "a stored order enables the button")
        XCTAssertNotEqual(topLevelNames(app), names.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending },
                          "the demo order is not Gmail's")

        button.click()
        let expected = names.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
        let deadline = Date().addingTimeInterval(5)
        while topLevelNames(app) != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(topLevelNames(app), expected, "the list is back in Gmail's order")
        XCTAssertFalse(button.isEnabled, "nothing stored: the button is disabled")
    }
}
