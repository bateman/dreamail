import XCTest

/// Regression: a one-message conversation opened in the reading pane showed
/// as a reduced, header-only card — as if it were an older message in a long
/// thread. It must open with its whole body and stay open: clicking the
/// header of the only message does not collapse it (Gmail on the web).
final class SingleMessageReadingPaneUITests: XCTestCase {
    private func launchReadingPane() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        // The short label list: a ~70-row sidebar makes every query slow.
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                // A saved accent must not change what this suite sees.
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-readingPaneHidden", "NO",
                                "-threadOpenStyle", "readingPane"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    /// One launch for both. The HTML check goes first, so t3 is still a
    /// never-seen message, as on a fresh launch; t1 (plain text) after it.
    func testOneMessageConversationsOpenFullyExpanded() {
        let app = launchReadingPane()
        XCTContext.runActivity(named: "An HTML message fills the pane from the first frame") { _ in
            stepHTMLMessageFillsThePaneFromTheFirstFrame(app) }
        XCTContext.runActivity(named: "A one-message conversation opens fully expanded") { _ in
            stepSingleMessageConversationOpensFullyExpanded(app) }
    }

    private func stepSingleMessageConversationOpensFullyExpanded(_ app: XCUIApplication) {
        // Demo t1 is a single message from Dana (plain text, several lines).
        let demoThread = app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t1").firstMatch
        XCTAssertTrue(demoThread.waitForExistence(timeout: 10))
        demoThread.click()
        let subject = app.staticTexts.matching(identifier: "threadSubject").firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 5))
        // t3 was open before: wait until the pane shows t1, so the checks
        // below read t1's card. A selectable Text exposes its string as the
        // value; the label is often empty.
        let text = { (subject.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? subject.label }
        let deadline = Date().addingTimeInterval(5)
        while !text().contains("Design review"), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(text().contains("Design review"), "the pane must show t1: \(text())")

        // Expanded: the body is mounted, without any click on the card.
        let body = app.descendants(matching: .any)
            .matching(identifier: "messageBody").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5),
                      "the only message must open expanded")
        // A collapsed card shows a single snippet line (~17 pt). The body of
        // t1 is eight lines of text.
        XCTAssertGreaterThan(body.frame.height, 3 * 17,
                             "the body must show at its full length, not a reduced card")
        XCTAssertFalse(app.buttons.matching(
            NSPredicate(format: "label == 'Collapse'")).firstMatch.exists,
                       "a one-message conversation offers no collapse control")

        // Clicking the header (its date) used to collapse the card into a
        // header-only row. It must stay open.
        let date = app.descendants(matching: .any)
            .matching(identifier: "messageHeaderDate").firstMatch
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        let heightBefore = body.frame.height
        date.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(body.exists, "the only message must not collapse")
        XCTAssertEqual(body.frame.height, heightBefore, accuracy: 1)
    }

    /// The reported symptom, HTML path: a never-seen HTML message opened as a
    /// 120 pt box for the whole WebKit load, then jumped to its length. The
    /// body must fill the pane from the first observation and only ever grow
    /// to its content (demo t3 is an HTML CI report taller than the window).
    private func stepHTMLMessageFillsThePaneFromTheFirstFrame(_ app: XCUIApplication) {
        let window = app.windows.firstMatch

        let row = app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t3").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()

        let body = app.descendants(matching: .any)
            .matching(identifier: "messageBody").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5),
                      "the only message must open expanded")
        // The body's span in the card: from the header's date to the action
        // bar right below the body. (The body's own accessibility frame is
        // the web view's, not the space its container reserves.)
        let date = app.descendants(matching: .any)
            .matching(identifier: "messageHeaderDate").firstMatch
        let reply = app.buttons.matching(identifier: "messageActionReply").firstMatch
        XCTAssertTrue(date.exists && reply.exists)
        let span = { reply.frame.minY - date.frame.maxY }
        let first = span()
        XCTAssertGreaterThan(first, 2.5 * 120,
                             "the body must not open as a 120 pt placeholder box")
        XCTAssertGreaterThan(first, 0.4 * window.frame.height,
                             "the open card must fill the reading pane while it loads")

        // The reservation holds until WebKit reports, so the span stays put
        // and then grows once to the content. Wait for the report (the
        // report is taller than the pane), checking it never shrinks below
        // what was first shown (no reduced stage, no stepwise jumps down).
        let target = window.frame.height * 0.9
        var last = first
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            last = span()
            XCTAssertGreaterThanOrEqual(last, first - 1,
                                        "the body must not shrink below its first frame")
            if last > target { break }
        }
        // Ends at the content height: the report is taller than the pane.
        XCTAssertGreaterThan(last, target,
                             "the body must end at its full content height")
    }
}

