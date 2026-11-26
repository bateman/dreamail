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
        // Exposes the thread rows' buttons and chips (the density step).
        app.launchEnvironment["DREAMAIL_UI_ROW_BUTTONS"] = "1"
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

    /// One launch for both; the band check first, before Settings opens.
    func testRail() {
        let app = launch()
        XCTContext.runActivity(named: "Window buttons lie inside the top band; the rail below is narrow") { _ in
            stepWindowButtonsLieInsideTheTopBandAndTheRailBelowIsNarrow(app) }
        XCTContext.runActivity(named: "The Appearance toggle hides and shows +") { _ in
            stepAppearanceToggleHidesAndShowsTheAddEntry(app) }
        XCTContext.runActivity(named: "The Compact density shortens the rows and Comfortable restores them") { _ in
            stepDensityShortensTheRowsAndComfortableRestoresThem(app) }
    }

    private func anyRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'threadRow.'")).firstMatch
    }

    private func openSettings(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(
            NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        return settings
    }

    /// Picks `title` in the list-density group of Settings → Appearance (live,
    /// no launch argument: it would override the picker), then closes Settings so
    /// the main window is the key window again.
    private func pickListDensity(_ app: XCUIApplication, _ title: String) {
        let settings = openSettings(app)
        let pane = element(settings, "settings.pane.appearance")
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        let choice = element(settings, "settings.listDensity").radioButtons[title]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "List density has a \(title) choice")
        choice.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "Settings closes")
    }

    private func rowFrameOnceSettled(_ app: XCUIApplication, _ id: String) -> CGRect {
        let row = element(app, id)
        XCTAssertTrue(row.waitForExistence(timeout: 15), "row \(id) is on screen")
        var last = row.frame
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let now = row.frame
            if now == last { return now }
            last = now
        }
        return last
    }

    /// Settings → Appearance → List density, picked live: Compact makes the
    /// rows shorter, the hover actions and label chips stay inside the row,
    /// Comfortable restores the height.
    private func stepDensityShortensTheRowsAndComfortableRestoresThem(_ app: XCUIApplication) {
        // Settings is still open from the step above: close it first.
        app.typeKey("w", modifierFlags: .command)
        let first = anyRow(app)
        XCTAssertTrue(first.waitForExistence(timeout: 15),
                      "demo inbox should load; windows \(app.windows.allElementsBoundByIndex.map { $0.title })")
        let id = first.identifier
        let comfortable = rowFrameOnceSettled(app, id).height

        pickListDensity(app, "Compact")
        let compactRow = element(app, id)
        XCTAssertTrue(waitUntil { abs((comfortable - compactRow.frame.height) - 8) <= 1.5 },
                      "compact rows are 8 pt shorter: \(comfortable) → \(compactRow.frame.height) pt")
        print("ThreadListDensity: comfortable row \(comfortable) pt, compact row \(compactRow.frame.height) pt")

        compactRow.hover()
        for action in ["archive", "trash", "toggleRead", "snooze"] {
            let b = compactRow.descendants(matching: .button)
                .matching(identifier: "rowAction.\(action)").firstMatch
            XCTAssertTrue(b.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(b.frame.minY, compactRow.frame.minY - 0.5, "\(action) above the row")
            XCTAssertLessThanOrEqual(b.frame.maxY, compactRow.frame.maxY + 0.5, "\(action) below the row")
        }
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'threadRow.'")).allElementsBoundByIndex
            .map(\.frame)
        for chip in app.descendants(matching: .any).matching(identifier: "rowLabelChip").allElementsBoundByIndex
        where !chip.frame.isEmpty {
            XCTAssertTrue(rows.contains { $0.insetBy(dx: -1, dy: -1).contains(chip.frame.insetBy(dx: 0, dy: 1)) },
                          "a label chip is clipped by its compact row: \(chip.frame)")
        }

        pickListDensity(app, "Comfortable")
        XCTAssertTrue(waitUntil { abs(element(app, id).frame.height - comfortable) <= 0.5 },
                      "comfortable restores the row height: \(element(app, id).frame.height) pt")
    }

    /// The top band covers the three window buttons (sidebar hidden, then
    /// shown), and the rail below it is 64 pt wide.
    private func stepWindowButtonsLieInsideTheTopBandAndTheRailBelowIsNarrow(_ app: XCUIApplication) {
        let settings = element(app, "accountRail.settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "the rail is on screen")
        let window = app.windows.firstMatch
        let band = element(app, "accountRail.topBand")
        XCTAssertTrue(band.waitForExistence(timeout: 5), "the top band is on screen")
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
        assertButtonsInBand("sidebar hidden")
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
        XCTAssertTrue(compose.waitForExistence(timeout: 5), "the sidebar is shown")
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
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        assertBandOverSidebar("conversation open")

        // Hidden again: back to the minimum.
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(waitUntil { abs(band.frame.width - 90) < 1 },
                      "sidebar hidden: the band is 90 pt wide (\(band.frame))")
        assertButtonsInBand("sidebar hidden again")
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
