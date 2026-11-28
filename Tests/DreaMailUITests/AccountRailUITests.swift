import XCTest

/// The account rail and its top band (the window's traffic lights lie on the
/// band), and the Appearance toggle that shows / hides the rail's "+" entry.
/// Demo inbox.
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
        XCTAssertTrue(app.windows.firstMatch.appears(timeout: 10))
        app.activate()
        return app
    }

    private func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// One launch for both; the band check first, before Settings opens.
    func testRail() {
        let app = launch()
        XCTContext.runActivity(named: "Window buttons lie inside the top band; the rail below is narrow") { _ in
            stepWindowButtonsLieInsideTheTopBandAndTheRailBelowIsNarrow(app) }
        XCTContext.runActivity(named: "The Appearance toggle hides and shows +") { _ in
            stepAppearanceToggleHidesAndShowsTheAddEntry(app) }
    }

    /// The top band covers the three window buttons (sidebar collapsed to its
    /// icon strip, then shown), and the rail below it is 64 pt wide.
    private func stepWindowButtonsLieInsideTheTopBandAndTheRailBelowIsNarrow(_ app: XCUIApplication) {
        let settings = element(app, "accountRail.settings")
        XCTAssertTrue(settings.appears(timeout: 10), "the rail is on screen")
        let window = app.windows.firstMatch
        let band = element(app, "accountRail.topBand")
        XCTAssertTrue(band.appears(timeout: 5), "the top band is on screen")
        let buttons = [window.buttons[XCUIIdentifierCloseWindow],
                       window.buttons[XCUIIdentifierMinimizeWindow],
                       window.buttons[XCUIIdentifierFullScreenWindow]]
        func assertButtonsInBand(_ when: String) {
            for button in buttons {
                XCTAssertTrue(button.exists)
                let b = band.frame
                let f = button.frame
                XCTAssertGreaterThanOrEqual(f.minX, b.minX, "\(when): \(button.identifier) \(f) in band \(b)")
                XCTAssertLessThanOrEqual(f.maxX, b.maxX, "\(when): \(button.identifier) \(f) in band \(b)")
                XCTAssertGreaterThanOrEqual(f.minY, b.minY, "\(when): \(button.identifier) \(f) in band \(b)")
                XCTAssertLessThanOrEqual(f.maxY, b.maxY, "\(when): \(button.identifier) \(f) in band \(b)")
            }
            let zoom = window.buttons[XCUIIdentifierFullScreenWindow]
            XCTAssertGreaterThanOrEqual(band.frame.maxX - zoom.frame.maxX, 8,
                                        "\(when): a visible margin right of the green button")
        }
        assertButtonsInBand("sidebar collapsed")
        XCTAssertEqual(band.frame.minX, window.frame.minX, accuracy: 1, "the band starts at the window's left edge")

        // The rail below the band: the settings gear is centred in it, so its
        // midline is half the rail's width from the window's left edge.
        let railWidth = (settings.frame.midX - window.frame.minX) * 2
        XCTAssertEqual(railWidth, 64, accuracy: 2, "the rail below the band is 64 pt wide")
        XCTAssertGreaterThanOrEqual(element(app, "accountRail.account.you@example.com").frame.minY, band.frame.maxY,
                                    "avatars start below the band")

        // Sidebar shown: the band runs over the sidebar's top, up to its
        // right edge, and the sidebar's content starts below it.
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let compose = element(app, "composeButton")
        XCTAssertTrue(compose.appears(timeout: 5), "the sidebar is shown")
        func assertBandOverSidebar(_ when: String) {
            XCTAssertTrue(waitUntil { band.frame.maxX > compose.frame.maxX },
                          "\(when): the band reaches the sidebar's right edge (\(band.frame), compose \(compose.frame))")
            XCTAssertLessThan(band.frame.maxX - compose.frame.maxX, 40,
                              "\(when): the band ends at the sidebar's right edge (\(band.frame), compose \(compose.frame))")
            XCTAssertGreaterThanOrEqual(compose.frame.minY, band.frame.maxY,
                                        "\(when): sidebar content starts below the band")
            assertButtonsInBand(when)
        }
        assertBandOverSidebar("sidebar shown")

        // The layout is rebuilt when a conversation opens: the band follows.
        let row = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(row.appears(timeout: 5))
        row.click()
        XCTAssertTrue(compose.appears(timeout: 5))
        assertBandOverSidebar("conversation open")

        // Collapsed again: the band covers rail + icon strip, no wider.
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(waitUntil { abs(band.frame.width - 104) < 1 },
                      "sidebar collapsed: the band is rail + strip, 104 pt wide (\(band.frame))")
        let strip = element(app, "sidebarStrip")
        XCTAssertTrue(strip.appears(timeout: 5), "the collapsed sidebar is the icon strip")
        XCTAssertEqual(strip.frame.maxX, band.frame.maxX, accuracy: 1,
                       "no step: strip and band end together (\(strip.frame), band \(band.frame))")
        assertButtonsInBand("sidebar hidden again")
    }

    /// The band's 90 pt state: a full-window conversation has no sidebar and
    /// no icon strip, and the band still covers the window buttons.
    func testBandInAFullWindowConversation() {
        let app = launch(extra: ["-threadOpenStyle", "fullWindow"])
        let window = app.windows.firstMatch
        let band = element(app, "accountRail.topBand")
        XCTAssertTrue(band.appears(timeout: 10))
        let row = element(app, "threadRow.you@example.com:t1")
        XCTAssertTrue(row.appears(timeout: 10))
        row.click()
        XCTAssertTrue(app.buttons.matching(identifier: "exitFocusButton").firstMatch
            .appears(timeout: 5), "the conversation fills the window")
        XCTAssertTrue(waitUntil { !self.element(app, "sidebarStrip").exists },
                      "no icon strip beside a full-window conversation")
        XCTAssertFalse(element(app, "composeButton").exists, "no sidebar either")
        XCTAssertTrue(waitUntil { abs(band.frame.width - 90) < 1 },
                      "full-window conversation: the band is 90 pt wide (\(band.frame))")
        for button in [window.buttons[XCUIIdentifierCloseWindow],
                       window.buttons[XCUIIdentifierMinimizeWindow],
                       window.buttons[XCUIIdentifierFullScreenWindow]] {
            let b = band.frame, f = button.frame
            XCTAssertTrue(f.minX >= b.minX && f.maxX <= b.maxX && f.minY >= b.minY && f.maxY <= b.maxY,
                          "\(button.identifier) \(f) in band \(b)")
        }
    }

    private func stepAppearanceToggleHidesAndShowsTheAddEntry(_ app: XCUIApplication) {
        let add = element(app, "accountRail.add")
        XCTAssertTrue(add.appears(timeout: 10), "+ is shown by default")

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(
            NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
        XCTAssertTrue(settings.appears(timeout: 5))
        let pane = element(settings, "settings.pane.appearance")
        XCTAssertTrue(pane.appears(timeout: 5))
        pane.click()
        let toggle = element(settings, "settings.showAddAccountInRail")
        XCTAssertTrue(toggle.appears(timeout: 5))

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
