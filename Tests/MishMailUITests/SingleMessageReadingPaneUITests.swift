import XCTest

/// Regression: a one-message conversation opened in the reading pane showed
/// as a reduced, header-only card — as if it were an older message in a long
/// thread. It must open with its whole body and stay open: clicking the
/// header of the only message does not collapse it (Gmail on the web).
final class SingleMessageReadingPaneUITests: XCTestCase {
    private func launchReadingPane() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
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

    func testSingleMessageConversationOpensFullyExpanded() {
        let app = launchReadingPane()

        // Demo t1 is a single message from Dana (plain text, several lines).
        let demoThread = app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t1").firstMatch
        XCTAssertTrue(demoThread.waitForExistence(timeout: 10))
        demoThread.click()
        XCTAssertTrue(app.staticTexts.matching(identifier: "threadSubject").firstMatch
            .waitForExistence(timeout: 5))

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
    func testHTMLMessageFillsThePaneFromTheFirstFrame() {
        let app = launchReadingPane()
        let window = app.windows.firstMatch

        let row = app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t3").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()

        let body = app.descendants(matching: .any)
            .matching(identifier: "messageBody").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5),
                      "the only message must open expanded")
        let first = body.frame.height
        XCTAssertGreaterThan(first, 2.5 * 120,
                             "the body must not open as a 120 pt placeholder box")
        XCTAssertGreaterThan(first, 0.4 * window.frame.height,
                             "the open card must fill the reading pane while it loads")

        // Settle: sample until two readings agree, and check it never shrinks
        // below what was first shown (no reduced stage, no stepwise jumps
        // back down).
        var last = first
        var settled = false
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let now = body.frame.height
            XCTAssertGreaterThanOrEqual(now, first - 1,
                                        "the body must not shrink below its first frame")
            if abs(now - last) < 1 { settled = true; break }
            last = now
        }
        XCTAssertTrue(settled, "the body height must settle")
        // Ends at the content height: the report is taller than the pane.
        XCTAssertGreaterThan(last, window.frame.height * 0.9,
                             "the body must end at its full content height")
    }
}

