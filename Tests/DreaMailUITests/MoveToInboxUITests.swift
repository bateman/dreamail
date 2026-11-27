import XCTest

/// Gmail's "Move to Inbox": archive a demo conversation from the Inbox, find
/// it in All Mail, where the row's archive slot reads "Move to Inbox", move
/// it back, see it stay in All Mail, and find it in the Inbox list again.
final class MoveToInboxUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        // The short label list: a ~70-row sidebar makes every query slow.
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        // Exposes the row's buttons to the accessibility tree (off by default).
        app.launchEnvironment["DREAMAIL_UI_ROW_BUTTONS"] = "1"
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

    private func row(_ app: XCUIApplication, _ id: String = "t3") -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:\(id)").firstMatch
    }

    private func button(_ row: XCUIElement, _ id: String) -> XCUIElement {
        row.descendants(matching: .button)
            .matching(identifier: "rowAction.\(id)").firstMatch
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    private func goTo(_ app: XCUIApplication, _ key: String) {
        app.typeKey("g", modifierFlags: [])
        app.typeKey(key, modifierFlags: [])
    }

    func testArchiveThenMoveBackToInboxFromAllMail() {
        let app = launch()
        XCTContext.runActivity(named: "Archive from the Inbox") { _ in
            let inboxRow = row(app)
            XCTAssertTrue(inboxRow.waitForExistence(timeout: 10), "demo inbox should load")
            inboxRow.hover()
            XCTAssertFalse(button(inboxRow, "moveToInbox").exists,
                           "an Inbox conversation offers Archive, not Move to Inbox")
            let archive = button(inboxRow, "archive")
            XCTAssertTrue(archive.waitForExistence(timeout: 5))
            archive.click()
            XCTAssertTrue(waitForDisappearance(inboxRow), "archive removes the row from the Inbox")
        }
        XCTContext.runActivity(named: "Move to Inbox from All Mail") { _ in
            goTo(app, "a")
            let allMailRow = row(app)
            XCTAssertTrue(allMailRow.waitForExistence(timeout: 10),
                          "the archived conversation is in All Mail")
            allMailRow.hover()
            let move = button(allMailRow, "moveToInbox")
            XCTAssertTrue(move.waitForExistence(timeout: 5),
                          "an archived conversation offers Move to Inbox in the archive slot")
            XCTAssertFalse(button(allMailRow, "archive").exists)
            move.click()
            // Gmail keeps it in All Mail; the slot turns back into Archive.
            XCTAssertTrue(allMailRow.waitForExistence(timeout: 5), "it stays in All Mail")
            allMailRow.hover()
            XCTAssertTrue(button(allMailRow, "archive").waitForExistence(timeout: 5),
                          "back in the Inbox, the row offers Archive again")
        }
        XCTContext.runActivity(named: "Back in the Inbox list") { _ in
            goTo(app, "i")
            XCTAssertTrue(row(app).waitForExistence(timeout: 10),
                          "the conversation is in the Inbox list again")
        }
    }
}
