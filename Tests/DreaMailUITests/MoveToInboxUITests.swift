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

    /// A context-menu item of `row`: by its identifier, else by its title
    /// inside the row's own menu (the menu bar has items of the same names).
    private func menuItem(_ app: XCUIApplication, _ row: XCUIElement,
                          _ id: String, _ title: String) -> XCUIElement {
        let byId = app.menuItems.matching(identifier: "rowMenu.\(id)").firstMatch
        return byId.waitForExistence(timeout: 2) ? byId : row.menuItems[title]
    }

    private func goTo(_ app: XCUIApplication, _ key: String) {
        app.typeKey("g", modifierFlags: [])
        app.typeKey(key, modifierFlags: [])
    }

    func testArchiveThenMoveBackToInboxFromAllMail() {
        let app = launch()
        XCTContext.runActivity(named: "An Inbox row's menu has Archive") { _ in
            let inboxRow = row(app)
            XCTAssertTrue(inboxRow.waitForExistence(timeout: 10), "demo inbox should load")
            inboxRow.rightClick()
            XCTAssertTrue(menuItem(app, inboxRow, "archive", "Archive").waitForExistence(timeout: 5))
            XCTAssertFalse(app.menuItems.matching(identifier: "rowMenu.moveToInbox").firstMatch.exists)
            XCTAssertFalse(inboxRow.menuItems["Move to inbox"].exists)
            app.typeKey(.escape, modifierFlags: [])
        }
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
            // Gmail's right-click menu, in its order: Reply …, Move to
            // inbox, Delete …, Move to…, Label as…, Mute.
            allMailRow.rightClick()
            let expected: [(String, String)] = [
                ("reply", "Reply"), ("replyAll", "Reply all"), ("forward", "Forward"),
                ("moveToInbox", "Move to inbox"), ("delete", "Delete"),
                ("markUnread", "Mark as unread"), ("snooze", "Snooze"),
                ("moveTo", "Move to…"), ("labelAs", "Label as…"), ("mute", "Mute"),
                ("findFromSender", "Find emails from"),
            ]
            var ys: [CGFloat] = []
            for (id, title) in expected {
                let item = id == "findFromSender"
                    ? app.menuItems.matching(NSPredicate(
                        format: "identifier == %@ OR title BEGINSWITH %@",
                        "rowMenu.findFromSender", "Find emails from ")).firstMatch
                    : menuItem(app, allMailRow, id, title)
                XCTAssertTrue(item.waitForExistence(timeout: 5), title)
                ys.append(item.frame.minY)
            }
            XCTAssertEqual(ys, ys.sorted(), "Gmail's order, top to bottom")
            XCTAssertFalse(app.menuItems.matching(identifier: "rowMenu.archive").firstMatch.exists)
            app.typeKey(.escape, modifierFlags: [])
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
