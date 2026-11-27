import XCTest

/// "Show Promotions and Social", per account: the two rows are in the
/// sidebar and in the icon strip while the setting is on (the default), and
/// in neither while it is off; `g p` then stays in the Inbox. Demo mailbox
/// (one account); the unified-scope rule is covered by `CategoryRowsTests`.
final class CategoryRowsUITests: XCTestCase {
    private let account = "you@example.com"

    private func launch(categoryRows: Bool?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane",
                                // Promotions and Social sit under "More": open it.
                                "-sidebar.more.expanded", "YES"]
        // `nil`: the stored setting decides (the test turns it off itself).
        if let categoryRows {
            app.launchArguments += ["-categoryRows.\(account)", categoryRows ? "YES" : "NO"]
        }
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    private func element(_ id: String, in app: XCUIElement) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    /// Collapsed strip first, then the full sidebar (→ reveals it).
    func testRowsAreAbsentWhileTheSettingIsOff() {
        let app = launch(categoryRows: false)
        XCTAssertTrue(element("threadRow.\(account):t3", in: app).waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        let spamStrip = element("sidebarStrip.spam", in: app)
        XCTAssertTrue(spamStrip.waitForExistence(timeout: 5), "More is open: Spam is listed")
        for id in ["sidebarStrip.promotions", "sidebarStrip.social"] {
            XCTAssertTrue(waitForAbsence(element(id, in: app)), "\(id) is not in the strip")
        }
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element("sidebar.spam", in: app).waitForExistence(timeout: 5))
        for id in ["sidebar.promotions", "sidebar.social"] {
            XCTAssertTrue(waitForAbsence(element(id, in: app)), "\(id) is not in the sidebar")
        }
        // `g p` is closed too: the Inbox stays on screen.
        app.typeKey("g", modifierFlags: [])
        app.typeKey("p", modifierFlags: [])
        XCTAssertTrue(element("threadRow.\(account):t3", in: app).waitForExistence(timeout: 5),
                      "g p falls back to the Inbox")
        XCTAssertFalse(element("sidebar.promotions", in: app).exists)
    }

    func testRowsAreListedWhileTheSettingIsOn() {
        let app = launch(categoryRows: true)
        XCTAssertTrue(element("threadRow.\(account):t3", in: app).waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        let promotionsStrip = element("sidebarStrip.promotions", in: app)
        let socialStrip = element("sidebarStrip.social", in: app)
        XCTAssertTrue(promotionsStrip.waitForExistence(timeout: 5))
        XCTAssertTrue(socialStrip.exists)
        XCTAssertLessThan(promotionsStrip.frame.minY, socialStrip.frame.minY)
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let promotions = element("sidebar.promotions", in: app)
        let social = element("sidebar.social", in: app)
        XCTAssertTrue(promotions.waitForExistence(timeout: 5))
        XCTAssertTrue(social.exists)
        XCTAssertLessThan(promotions.frame.minY, social.frame.minY)
    }

    /// Turning the setting off in Settings while Promotions is on screen
    /// leaves it for the Inbox and removes the row.
    func testTurningTheSettingOffLeavesTheOpenView() {
        let app = launch(categoryRows: nil)
        XCTAssertTrue(element("threadRow.\(account):t3", in: app).waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let promotions = element("sidebar.promotions", in: app)
        XCTAssertTrue(promotions.waitForExistence(timeout: 5))
        promotions.click()
        // The launch argument does not stop the toggle from writing the
        // stored setting: flip it back at the end so no other suite inherits it.
        func flip() {
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows.matching(
                NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            let pane = element("settings.pane.accounts", in: settings)
            XCTAssertTrue(pane.waitForExistence(timeout: 5))
            pane.click()
            let toggle = element("settings.account.categoryRows.\(account)", in: settings)
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.click()
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        }
        flip()
        XCTAssertTrue(waitForAbsence(element("sidebar.promotions", in: app)),
                      "the row is gone")
        XCTAssertTrue(element("threadRow.\(account):t3", in: app).waitForExistence(timeout: 5),
                      "the Inbox is on screen")
        flip()
        XCTAssertTrue(element("sidebar.promotions", in: app).waitForExistence(timeout: 5),
                      "turned on again: the row is back, and the setting is left as found")
    }
}
