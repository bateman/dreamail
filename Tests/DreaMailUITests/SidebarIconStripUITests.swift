import XCTest

/// The collapsed sidebar: an icon strip right of the account rail that fills
/// the top band's step, with Search, the system views and "More". Demo inbox.
/// Leaves the sidebar collapsed and "More" closed, as the other suites expect.
final class SidebarIconStripUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
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

    /// One launch: every step starts and ends with the sidebar collapsed.
    func testIconStrip() {
        let app = launch()
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").waitForExistence(timeout: 10))
        // Collapsed whatever an earlier suite left.
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTContext.runActivity(named: "The strip shows icons only, aligned with the band") { _ in
            stepStripShowsIconsAlignedWithTheBand(app) }
        XCTContext.runActivity(named: "Clicking an icon opens its view") { _ in
            stepClickingAnIconOpensTheView(app) }
        XCTContext.runActivity(named: "More shows and hides the icons under it") { _ in
            stepMoreShowsAndHidesItsIcons(app) }
        XCTContext.runActivity(named: "Search expands the sidebar with the field focused") { _ in
            stepSearchExpandsTheSidebarAndFocusesTheField(app) }
        XCTContext.runActivity(named: "Toggling restores the full sidebar at its width") { _ in
            stepTogglingRestoresTheFullSidebarAtItsWidth(app) }
    }

    private func stepStripShowsIconsAlignedWithTheBand(_ app: XCUIApplication) {
        let strip = element(app, "sidebarStrip")
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "the collapsed sidebar is the icon strip")
        for id in ["search", "inbox", "starred", "snoozed", "important", "sent", "drafts",
                   "allMail", "trash", "more"] {
            XCTAssertTrue(element(app, "sidebarStrip.\(id)").exists, "strip icon \(id)")
        }
        // Icons only: no full-sidebar rows, labels, saved views or titles.
        XCTAssertFalse(element(app, "sidebar.inbox").exists, "no full sidebar row")
        XCTAssertFalse(element(app, "composeButton").exists, "no sidebar header")
        XCTAssertFalse(element(app, "sidebar.labels.add").exists, "no Labels section")
        let labelRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.label.'"))
        XCTAssertEqual(labelRows.count, 0, "no label rows")
        XCTAssertFalse(app.staticTexts["Views"].exists, "no Views header")

        let window = app.windows.firstMatch
        let band = element(app, "accountRail.topBand")
        XCTAssertTrue(band.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { abs(band.frame.maxX - strip.frame.maxX) <= 1 },
                      "strip and band end together (\(strip.frame), band \(band.frame))")
        XCTAssertEqual(strip.frame.minX - window.frame.minX, 64, accuracy: 1,
                       "the strip starts at the rail's right edge (\(strip.frame))")
        XCTAssertEqual(strip.frame.width, 40, accuracy: 1, "the strip is 40 pt wide")
        XCTAssertEqual(band.frame.width, 104, accuracy: 1, "the band is rail + strip wide")
        XCTAssertGreaterThanOrEqual(element(app, "sidebarStrip.search").frame.minY, band.frame.maxY,
                                    "the icons start below the band")
        let inbox = element(app, "sidebarStrip.inbox")
        XCTAssertTrue(inbox.isSelected, "the open view's icon is selected")
    }

    private func stepClickingAnIconOpensTheView(_ app: XCUIApplication) {
        let unstarred = element(app, "threadRow.you@example.com:t3")
        XCTAssertTrue(unstarred.waitForExistence(timeout: 5))
        element(app, "sidebarStrip.starred").click()
        XCTAssertTrue(waitUntil { !unstarred.exists }, "Starred leaves the unstarred thread")
        XCTAssertTrue(element(app, "threadRow.you@example.com:t1").waitForExistence(timeout: 5),
                      "Starred lists the starred thread")
        XCTAssertTrue(waitUntil { self.element(app, "sidebarStrip.starred").isSelected },
                      "the Starred icon is now selected")
        XCTAssertTrue(element(app, "sidebarStrip").exists, "the sidebar stays collapsed")
        element(app, "sidebarStrip.inbox").click()
        XCTAssertTrue(unstarred.waitForExistence(timeout: 5), "back to the inbox")
    }

    private func stepMoreShowsAndHidesItsIcons(_ app: XCUIApplication) {
        let more = element(app, "sidebarStrip.more")
        let spam = element(app, "sidebarStrip.spam")
        XCTAssertTrue(more.exists)
        // Closed by default (and as the other suites leave it).
        if spam.exists { more.click() }
        XCTAssertTrue(waitUntil { !spam.exists }, "a closed More hides the icons under it")
        more.click()
        XCTAssertTrue(spam.waitForExistence(timeout: 5), "an open More lists Spam")
        XCTAssertGreaterThan(spam.frame.minY, more.frame.maxY - 1, "below More")
        // The full sidebar shows the same state.
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebar.spam").waitForExistence(timeout: 5),
                      "the full sidebar shares the open More")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").waitForExistence(timeout: 5))
        more.click()
        XCTAssertTrue(waitUntil { !spam.exists }, "closing More hides Spam again")
    }

    private func stepSearchExpandsTheSidebarAndFocusesTheField(_ app: XCUIApplication) {
        element(app, "sidebarStrip.search").click()
        XCTAssertTrue(element(app, "composeButton").waitForExistence(timeout: 5), "the sidebar expands")
        XCTAssertTrue(waitUntil { !self.element(app, "sidebarStrip").exists }, "the strip is gone")
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue == 'Search'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false },
                      "the search field has the focus")
        // Esc leaves the field; ← collapses again.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").waitForExistence(timeout: 5))
    }

    private func stepTogglingRestoresTheFullSidebarAtItsWidth(_ app: XCUIApplication) {
        let band = element(app, "accountRail.topBand")
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let compose = element(app, "composeButton")
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { band.frame.width > 200 }, "the band runs over the full sidebar")
        // Settled width of the full sidebar (the band follows its edge).
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let fullWidth = band.frame.width
        XCTAssertFalse(element(app, "sidebarStrip").exists, "no strip next to the full sidebar")

        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").waitForExistence(timeout: 5), "collapsed to the strip")
        XCTAssertTrue(waitUntil { abs(band.frame.width - 104) < 1 }, "band back to rail + strip")

        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { abs(band.frame.width - fullWidth) <= 1 },
                      "the full sidebar comes back at its width (\(band.frame.width) vs \(fullWidth))")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").waitForExistence(timeout: 5))
    }
}
