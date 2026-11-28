import XCTest

/// Gmail web's "1 deleted message in this conversation · View" line. Demo
/// t11 has two live messages around one in the Trash: the line shows the
/// count, "View" shows the deleted message marked "In Trash", "Hide" hides
/// it, "Restore" makes it a normal message and the line goes. The list row
/// never shows the deleted message while it is viewed.
final class DeletedMessagesInConversationUITests: XCTestCase {
    private let account = "you@example.com"
    /// The deleted message's snippet: never in the list row.
    private let deletedSnippet = "tap by the shed"

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-readingPaneHidden", "NO",
                                "-threadOpenStyle", "readingPane",
                                "-fontScale", "1.0"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.appears(timeout: 10))
        app.activate()
        return app
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func count(_ id: String, in app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex
            .filter { !$0.frame.isEmpty }.count
    }

    private func wait(_ what: String, timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line,
                      until ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ready() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("timed out: \(what)", file: file, line: line)
    }

    private var rowId: String { "threadRow.\(account):t11" }

    /// t11 is the oldest Inbox conversation: scroll the list down to it.
    private func revealRow(_ app: XCUIApplication) -> XCUIElement {
        let row = element(rowId, in: app)
        let anchor = element("threadRow.\(account):t1", in: app)
        XCTAssertTrue(anchor.appears(timeout: 10))
        var tries = 0
        while !(row.exists && row.isHittable), tries < 15 {
            let target = row.exists ? row : anchor
            if target.exists { target.scroll(byDeltaX: 0, deltaY: -300) }
            tries += 1
        }
        XCTAssertTrue(row.exists && row.isHittable, "the t11 row is on screen")
        return row
    }

    /// The row's text, and that the deleted message is not in it.
    private func rowText(_ app: XCUIApplication, file: StaticString = #filePath,
                         line: UInt = #line) -> String {
        let row = revealRow(app)
        let texts = row.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
        let text = ([row.label] + texts).joined(separator: " | ")
        XCTAssertFalse(text.contains(deletedSnippet), "the row never shows the deleted message: \(text)",
                       file: file, line: line)
        return text
    }

    private func showList(_ app: XCUIApplication) {
        let back = app.buttons.matching(identifier: "compactBackButton").firstMatch
        if back.exists { back.click() }
    }

    private func open(_ app: XCUIApplication) {
        revealRow(app).click()
        XCTAssertTrue(element("threadSubject", in: app).appears(timeout: 5))
        wait("two live messages") { count("messageRowFrame", in: app) == 2 }
    }

    func testDeletedMessageLineViewHideRestore() {
        let app = launch()
        let before = rowText(app)
        open(app)

        let line = element("thread.deletedMessages", in: app)
        XCTAssertTrue(line.appears(timeout: 5), "the line is shown")
        XCTAssertEqual(line.label, "1 deleted message in this conversation")
        XCTAssertFalse(element("messageInTrashTag", in: app).exists)

        XCTContext.runActivity(named: "View shows the deleted message marked In Trash") { _ in
            let view = element("thread.deletedMessages.view", in: app)
            XCTAssertTrue(view.appears(timeout: 5))
            view.click()
            XCTAssertTrue(element("messageInTrashTag", in: app).appears(timeout: 5))
            wait("three rows") { count("messageRowFrame", in: app) == 3 }
            XCTAssertTrue(element("thread.deletedMessages.hide", in: app).exists)
            XCTAssertTrue(element("thread.deletedMessages.restoreAll", in: app).exists)
        }

        XCTContext.runActivity(named: "The list row did not change while viewing") { _ in
            showList(app)
            XCTAssertEqual(rowText(app), before)
            // Not remembered: reopening shows the line with View again.
            open(app)
            XCTAssertTrue(element("thread.deletedMessages.view", in: app).appears(timeout: 5))
            XCTAssertFalse(element("messageInTrashTag", in: app).exists)
        }

        XCTContext.runActivity(named: "Hide hides it") { _ in
            element("thread.deletedMessages.view", in: app).click()
            XCTAssertTrue(element("messageInTrashTag", in: app).appears(timeout: 5))
            let hide = element("thread.deletedMessages.hide", in: app)
            XCTAssertTrue(hide.appears(timeout: 5))
            hide.click()
            wait("the deleted message is hidden") {
                !element("messageInTrashTag", in: app).exists && count("messageRowFrame", in: app) == 2
            }
            XCTAssertTrue(element("thread.deletedMessages.view", in: app).exists)
        }

        XCTContext.runActivity(named: "Restore makes it a normal message; the line goes") { _ in
            element("thread.deletedMessages.view", in: app).click()
            XCTAssertTrue(element("messageInTrashTag", in: app).appears(timeout: 5))
            let expand = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Open deleted message from'")).firstMatch
            XCTAssertTrue(expand.appears(timeout: 5))
            expand.click()
            let restore = element("messageActionRestore", in: app)
            XCTAssertTrue(restore.appears(timeout: 5))
            // The open card is the deleted one (one open card at a time):
            // it has no reply bar.
            XCTAssertEqual(count("messageActionReply", in: app), 0, "a deleted message offers no reply")
            restore.click()
            wait("the line disappears") { !element("thread.deletedMessages", in: app).exists }
            wait("three normal messages") {
                count("messageRowFrame", in: app) == 3 && !element("messageInTrashTag", in: app).exists
            }
        }
    }
}
