import XCTest

/// The account's avatar carries an unread badge: with the demo account
/// chosen, the switcher header reads "N unread" (the badge sits on the
/// avatar, which the header's label includes). Demo inbox only: its one
/// account has unread mail in the primary inbox.
final class AccountUnreadBadgeUITests: XCTestCase {
    func testSwitcherAvatarShowsTheAccountsUnreadCount() {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").waitForExistence(timeout: 10),
                      "demo inbox should load")
        // Sidebar starts collapsed; → reveals it (as in AccountLabelColorUITests).
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])

        let switcher = element(app, "accountSwitcher")
        XCTAssertTrue(switcher.waitForExistence(timeout: 5), "account switcher in the sidebar")
        XCTAssertFalse(switcher.label.contains("unread"),
                       "the unified entry shows no badge: \(switcher.label)")
        switcher.click()
        let row = app.popovers.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Personal")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the account row is in the switcher")
        row.click()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        let badged = NSPredicate(format: "label MATCHES %@", ".*, [0-9]+ unread$")
        expectation(for: badged, evaluatedWith: switcher)
        waitForExpectations(timeout: 10)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
}
