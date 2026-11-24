import XCTest

/// Regression: a one-message conversation opened in the reading pane showed
/// as a reduced, header-only card — as if it were an older message in a long
/// thread. It must open with its whole body and stay open: clicking the
/// header of the only message does not collapse it (Gmail on the web).
final class SingleMessageReadingPaneUITests: XCTestCase {
    func testSingleMessageConversationOpensFullyExpanded() {
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
}
