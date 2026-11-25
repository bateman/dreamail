import XCTest

/// The account rail: the window's traffic lights lie over it, and the
/// Appearance toggle shows / hides its "+" entry. Demo inbox.
final class AccountRailUITests: XCTestCase {
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        // The short label list: a ~70-row sidebar makes every query slow.
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"] + extra
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    private func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// One launch for both; the window check first, before Settings opens.
    func testRail() {
        let app = launch()
        XCTContext.runActivity(named: "Window buttons lie entirely over the rail") { _ in
            stepWindowButtonsLieEntirelyOverTheRail(app) }
        XCTContext.runActivity(named: "The Appearance toggle hides and shows +") { _ in
            stepAppearanceToggleHidesAndShowsTheAddEntry(app) }
    }

    private func stepWindowButtonsLieEntirelyOverTheRail(_ app: XCUIApplication) {
        let settings = element(app, "accountRail.settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "the rail is on screen")
        let window = app.windows.firstMatch
        // The rail's right edge: the settings gear is centred in it, so its
        // midline is half the rail's width from the window's left edge.
        let railRight = window.frame.minX + (settings.frame.midX - window.frame.minX) * 2
        for button in [window.buttons[XCUIIdentifierCloseWindow],
                       window.buttons[XCUIIdentifierMinimizeWindow],
                       window.buttons[XCUIIdentifierFullScreenWindow]] {
            XCTAssertTrue(button.exists)
            XCTAssertLessThan(button.frame.maxX, railRight,
                              "window button \(button.identifier) \(button.frame) must lie inside the rail (right edge \(railRight), window \(window.frame))")
        }
        let zoom = window.buttons[XCUIIdentifierFullScreenWindow]
        XCTAssertGreaterThanOrEqual(railRight - zoom.frame.maxX, 8,
                                    "a visible margin right of the green button")
    }

    private func stepAppearanceToggleHidesAndShowsTheAddEntry(_ app: XCUIApplication) {
        let add = element(app, "accountRail.add")
        XCTAssertTrue(add.waitForExistence(timeout: 10), "+ is shown by default")

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(
            NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let pane = element(settings, "settings.pane.appearance")
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        let toggle = element(settings, "settings.showAddAccountInRail")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        toggle.click()
        XCTAssertTrue(waitUntil { !add.exists }, "+ disappears at once with the toggle off")
        toggle.click()
        XCTAssertTrue(waitUntil { add.exists }, "+ comes back with the toggle on")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }
}
