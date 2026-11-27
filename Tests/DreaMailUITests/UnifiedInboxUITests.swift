import XCTest

/// Settings → Appearance → "Show unified inbox (All accounts)": the rail's
/// "All accounts" button, ⌘1 and the view on screen follow it; the avatars
/// keep their geometry; the choice survives a relaunch. Demo inbox with a
/// second, empty account (`DREAMAIL_DEMO_SECOND_ACCOUNT`), so the rail has
/// the button.
final class UnifiedInboxUITests: XCTestCase {
    private let first = "accountRail.account.you@example.com"
    private let second = "accountRail.account.zoe@example.com"

    private func launch(unified: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_SECOND_ACCOUNT"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"]
        if let unified { app.launchArguments += ["-showUnifiedInbox", unified] }
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

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    /// Flips the switch in Settings, then closes Settings (the main window
    /// takes the keys again).
    private func flipSetting(_ app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let pane = element(settings, "settings.pane.appearance")
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        let toggle = element(settings, "settings.showUnifiedInbox")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil { !settings.exists })
    }

    func testSettingHidesTheButtonAndEveryWayIn() {
        let app = launch(unified: "YES")
        let all = element(app, "accountRail.all")
        let a = element(app, first), b = element(app, second)
        XCTAssertTrue(all.waitForExistence(timeout: 10), "on by default: the button is in the rail")
        XCTAssertTrue(a.exists && b.exists)
        let allOn = all.frame, aOn = a.frame, bOn = b.frame
        XCTAssertTrue(all.isSelected, "the unified view is the one on screen")
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").waitForExistence(timeout: 10))

        // Off while the unified view is on screen: the same view, one account.
        flipSetting(app)
        XCTAssertTrue(waitUntil { !all.exists }, "the button leaves the rail")
        XCTAssertTrue(waitUntil { a.isSelected && !b.isSelected },
                      "the first account in rail order is on screen instead")
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").waitForExistence(timeout: 10),
                      "its inbox is listed")
        // Geometry: no empty slot where the button was; same size and column.
        XCTAssertEqual(a.frame.minY, allOn.minY, accuracy: 1, "the first avatar takes the button's slot")
        XCTAssertEqual(b.frame.minY, aOn.minY, accuracy: 1, "the second takes the first's")
        for (now, before) in [(a.frame, aOn), (b.frame, bOn)] {
            XCTAssertEqual(now.width, before.width, accuracy: 0.5)
            XCTAssertEqual(now.height, before.height, accuracy: 0.5)
            XCTAssertEqual(now.minX, before.minX, accuracy: 0.5)
        }

        // ⌘1 no longer means "All accounts": it is the first account; ⌘2 the second.
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(waitUntil { b.isSelected && !a.isSelected })
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(waitUntil { a.isSelected && !b.isSelected }, "⌘1 selects the first account")
        XCTAssertFalse(all.exists)
        app.typeKey("3", modifierFlags: .command)
        XCTAssertFalse(all.exists, "no digit reaches the unified view")
        XCTAssertTrue(a.isSelected)

        // On again: the button returns, avatars are where they were.
        flipSetting(app)
        XCTAssertTrue(all.waitForExistence(timeout: 5), "the button is back")
        XCTAssertEqual(all.frame.minY, allOn.minY, accuracy: 1)
        XCTAssertEqual(a.frame.minY, aOn.minY, accuracy: 1)
        XCTAssertEqual(b.frame.minY, bOn.minY, accuracy: 1)
        XCTAssertTrue(a.isSelected, "nothing else changes: the account stays on screen")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(waitUntil { all.isSelected }, "⌘1 is All accounts again")
    }

    func testSettingPersistsAndAppliesAtLaunch() {
        var app = launch(unified: "YES")
        XCTAssertTrue(element(app, "accountRail.all").waitForExistence(timeout: 10))
        flipSetting(app)
        XCTAssertTrue(waitUntil { !self.element(app, "accountRail.all").exists })
        app.terminate()

        // Relaunch with no argument: the stored "off" decides. The view at
        // launch is the first account's, not the unified one.
        app = launch()
        XCTAssertTrue(element(app, first).waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "accountRail.all").exists, "still off after a relaunch")
        XCTAssertTrue(waitUntil { self.element(app, self.first).isSelected },
                      "launches on the first account")

        // Put the default back for the other tests.
        flipSetting(app)
        XCTAssertTrue(element(app, "accountRail.all").waitForExistence(timeout: 5))
    }
}
