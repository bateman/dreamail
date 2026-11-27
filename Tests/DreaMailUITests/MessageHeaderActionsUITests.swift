import XCTest

/// The header of an open message, as Gmail on the web: after the date, the
/// star, Reply, Reply all and "More" (⋮), whose menu keeps Gmail's order.
/// The star belongs to that message only; a conversation with a starred
/// message opens on it; "Delete this message" trashes only that message and
/// the conversation stays in the Inbox, with Undo.
/// Demo t7 is one message copied to a second person (Reply all differs from
/// Reply), already starred; demo t2 has four messages, none starred.
final class MessageHeaderActionsUITests: XCTestCase {
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
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func frames(_ identifier: String, in app: XCUIApplication) -> [CGRect] {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
            .map(\.frame)
            .filter { !$0.isEmpty }
            .sorted { $0.minY < $1.minY }
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// Frames once two reads 0.3 s apart agree and `ready` holds.
    private func settled(_ identifier: String, in app: XCUIApplication,
                         until ready: ([CGRect]) -> Bool) -> [CGRect] {
        var last = frames(identifier, in: app)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let now = frames(identifier, in: app)
            if now == last, ready(now) { return now }
            last = now
        }
        XCTFail("\(identifier) did not settle: \(last)")
        return last
    }

    /// The narrow default window shows the conversation in place of the
    /// list: its back button brings the list back.
    private func showList(_ app: XCUIApplication) {
        let back = app.buttons.matching(identifier: "compactBackButton").firstMatch
        if back.exists { back.click() }
    }

    private func open(_ app: XCUIApplication, _ thread: String) {
        showList(app)
        let row = element(app, "threadRow.you@example.com:\(thread)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), thread)
        row.click()
        XCTAssertTrue(element(app, "threadSubject").waitForExistence(timeout: 5))
    }

    private func readingPane(_ app: XCUIApplication) -> XCUIElement {
        app.scrollViews.containing(
            NSPredicate(format: "identifier == 'threadSubject'")).firstMatch
    }

    func testMessageHeaderActions() {
        let app = launch()
        let steps: [(String, (XCUIApplication) -> Void)] = [
            ("Star, Reply, Reply all and More follow the date", stepControlsFollowTheDate),
            ("More lists Gmail's items in Gmail's order", stepMoreMenuKeepsGmailsOrder),
            ("The star is the message's own; the conversation opens on it", stepStarredMessageOpensTheConversation),
            ("Delete this message keeps the conversation in the Inbox, with Undo", stepDeleteThisMessage),
        ]
        for (name, step) in steps {
            XCTContext.runActivity(named: name) { _ in step(app) }
        }
    }

    private func stepControlsFollowTheDate(_ app: XCUIApplication) {
        open(app, "t7")
        let ids = ["messageHeaderStar", "messageHeaderReply", "messageHeaderReplyAll", "messageHeaderMore"]
        for id in ids {
            XCTAssertTrue(element(app, id).waitForExistence(timeout: 5), "\(id) is in the header")
        }
        let date = element(app, "messageHeaderDate").frame
        let sender = element(app, "messageSender").frame
        let controls = ids.map { element(app, $0).frame }
        print("MessageHeaderActions: sender \(sender), date \(date), controls \(controls)")
        XCTAssertEqual(controls.map(\.minX), controls.map(\.minX).sorted(),
                       "star, reply, reply all, more: in this order")
        XCTAssertGreaterThanOrEqual(controls[0].minX, date.maxX, "after the date")
        XCTAssertLessThanOrEqual(sender.maxX, date.minX + 1, "the sender line ends before the date")
        for frame in controls {
            XCTAssertEqual(frame.midY, date.midY, accuracy: 6, "on the name line")
        }
        XCTAssertEqual(element(app, "messageHeaderStar").label, "Unstar this message",
                       "the starred demo message shows its star")
    }

    /// The open "More" menu: the menu holding an item only it has, so the
    /// menu bar's own Reply / Forward items never match.
    private func moreMenu(_ app: XCUIApplication) -> XCUIElement {
        app.menus.containing(NSPredicate(format: "title == 'Mark unread from here'")).firstMatch
    }

    private func stepMoreMenuKeepsGmailsOrder(_ app: XCUIApplication) {
        element(app, "messageHeaderMore").click()
        let expected = ["Reply", "Reply to all", "Forward", "Filter messages like this",
                        "Delete this message", "Block \"Marcus Bell\"", "Report spam",
                        "Show original", "Download message", "Mark unread from here"]
        let menu = moreMenu(app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the menu opens")
        var tops: [CGFloat] = []
        for title in expected {
            let item = menu.menuItems[title]
            XCTAssertTrue(item.exists, "\(title) is in the menu")
            tops.append(item.frame.minY)
        }
        XCTAssertEqual(tops, tops.sorted(), "Gmail's order")
        for gone in ["Report phishing", "Translate message", "Print"] {
            XCTAssertFalse(menu.menuItems[gone].exists, "\(gone) is left out, not disabled")
        }
        XCTAssertFalse(menu.menuItems.matching(NSPredicate(format: "title CONTAINS 'Contacts'"))
            .firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Stars the oldest message of t2, then opens t2 again: it opens on
    /// that message, expanded and in view; the newest stays open too (no
    /// unread mail is newer than the star once t2 has been read).
    private func stepStarredMessageOpensTheConversation(_ app: XCUIApplication) {
        open(app, "t2")
        let rows = settled("messageRowFrame", in: app) { $0.count == 4 }
        guard rows.count == 4 else { return }
        // Past the 1 s read-on-open dwell: t2 is read before the star.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let pane = readingPane(app)
        if pane.exists { pane.scroll(byDeltaX: 0, deltaY: 2000) }
        let oldest = app.buttons.matching(identifier: "messageRowExpand")
            .allElementsBoundByIndex.min { $0.frame.minY < $1.frame.minY }
        XCTAssertNotNil(oldest)
        oldest?.click()
        let opened = settled("messageRowFrame", in: app) {
            $0.count == 4 && $0[0].height > $0[1].height + 40
        }
        guard opened.count == 4 else { return }
        // One open message: one star, the oldest's.
        let star = element(app, "messageHeaderStar")
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        XCTAssertEqual(star.label, "Star this message")
        star.click()
        XCTAssertTrue(waitUntil { star.label == "Unstar this message" }, "the message is starred")
        XCTAssertEqual(frames("messageHeaderStar", in: app).count, 1,
                       "the other messages keep their own state")

        // Away and back: t2 opens on its starred message.
        open(app, "t1")
        open(app, "t2")
        let reopened = settled("messageRowFrame", in: app) {
            $0.count == 4 && $0.contains { $0.height > 160 }
        }
        guard reopened.count == 4 else { return }
        let heights = reopened.map(\.height)
        print("MessageHeaderActions: rows after reopening \(reopened.map { [$0.minY, $0.height] })")
        XCTAssertGreaterThan(heights[0], heights[1] + 40, "the starred (oldest) message is open")
        XCTAssertLessThan(heights[1], 100, "a read message between them is collapsed")
        XCTAssertLessThan(heights[2], 100)
        XCTAssertGreaterThan(heights[3], heights[1] + 40, "the newest stays open")
        let paneFrame = readingPane(app).frame
        XCTAssertTrue(paneFrame.intersects(reopened[0]), "the starred message is in view")
        XCTAssertGreaterThanOrEqual(reopened[0].minY, paneFrame.minY - 0.5,
                                    "its header is not above the pane")
        let stars = app.descendants(matching: .any).matching(identifier: "messageHeaderStar")
            .allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(stars.first?.label, "Unstar this message", "the top open message is the starred one")
    }

    /// One open message of t2 goes to the Trash alone: the conversation
    /// keeps its other messages and its place in the Inbox; Undo brings
    /// the message back. Independent of the other steps: it takes the top
    /// open message, whichever the conversation opened on.
    private func stepDeleteThisMessage(_ app: XCUIApplication) {
        open(app, "t2")
        let before = settled("messageRowFrame", in: app) { $0.count >= 2 }
        let count = before.count
        let more = app.descendants(matching: .any).matching(identifier: "messageHeaderMore")
            .allElementsBoundByIndex.filter { !$0.frame.isEmpty }
            .min { $0.frame.minY < $1.frame.minY }
        XCTAssertNotNil(more, "an open message has More")
        more?.click()
        let delete = moreMenu(app).menuItems["Delete this message"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        let left = settled("messageRowFrame", in: app) { $0.count == count - 1 }
        XCTAssertEqual(left.count, count - 1, "only that message leaves the conversation")
        XCTAssertTrue(element(app, "threadSubject").exists, "the conversation stays open")

        showList(app)
        XCTAssertTrue(element(app, "threadRow.you@example.com:t2").waitForExistence(timeout: 5),
                      "the conversation is still in the Inbox")

        let undo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Undo'")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the delete offers Undo")
        undo.click()
        open(app, "t2")
        let back = settled("messageRowFrame", in: app) { $0.count == count }
        XCTAssertEqual(back.count, count, "Undo brings the message back")
    }
}
