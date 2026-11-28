import XCTest

/// The account's avatar carries an unread badge: with the demo account
/// chosen, the rail avatar's value reads "N unread" (the badge sits on the
/// avatar, which is hidden from VoiceOver; the button carries the value). Demo inbox only: its one
/// account has unread mail in the primary inbox.
final class AccountUnreadBadgeUITests: XCTestCase {
    func testRailAvatarShowsTheAccountsUnreadCount() {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        // The short label list: a ~70-row sidebar makes every query slow.
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.appears(timeout: 10))
        app.activate()
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").appears(timeout: 10),
                      "demo inbox should load")
        // The rail is always visible, also with the sidebar collapsed.
        let all = element(app, "accountRail.all")
        // One demo account: no "All accounts" entry, and the account avatar
        // carries the badge as its value.
        XCTAssertFalse(all.exists, "no unified entry with a single account")
        let account = element(app, "accountRail.account.you@example.com")
        XCTAssertTrue(account.appears(timeout: 5), "account avatar in the rail")
        account.click()
        let badged = NSPredicate(format: "value MATCHES %@", "[0-9]+ unread")
        expectation(for: badged, evaluatedWith: account)
        waitForExpectations(timeout: 10)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
}
