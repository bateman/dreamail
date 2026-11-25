import XCTest

/// Gmail's keys inside an open conversation, on demo t2 (four messages; the
/// newest opens expanded, the three before it collapsed): `p` / `n` move
/// the open message, `;` opens every message, `:` closes them all.
/// A collapsed row exposes a `messageRowExpand` button; an open one does not.
final class ConversationKeysUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        // The short label list: a ~70-row sidebar makes every query slow.
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-readingPaneHidden", "NO",
                                "-threadOpenStyle", "readingPane",
                                // Stored overrides must not move n / p / ; / :.
                                "-keyBindings", "",
                                "-fontScale", "1.0"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    private func rows(_ app: XCUIApplication) -> [CGRect] {
        app.descendants(matching: .any).matching(identifier: "messageRowFrame")
            .allElementsBoundByIndex.map(\.frame).filter { !$0.isEmpty }
            .sorted { $0.minY < $1.minY }
    }

    private func collapsedCount(_ app: XCUIApplication) -> Int {
        app.buttons.matching(identifier: "messageRowExpand").count
    }

    /// Waits until `check` holds (the layout animates for 0.12 s).
    private func wait(_ what: String, _ check: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if check() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("timed out: \(what)", file: file, line: line)
    }

    /// Index (oldest first) of the tallest row: the open message.
    private func openIndex(_ app: XCUIApplication) -> Int? {
        let frames = rows(app)
        guard frames.count == 4 else { return nil }
        return frames.indices.max { frames[$0].height < frames[$1].height }
    }

    /// One launch for both checks; each opens t2 afresh (see
    /// `openConversation`).
    func testMessageKeys() {
        let app = launch()
        XCTContext.runActivity(named: "p and n move the open message") { _ in
            stepPreviousAndNextMessageMoveTheOpenMessage(app) }
        XCTContext.runActivity(named: "; expands all, : collapses all") { _ in
            stepExpandAllAndCollapseAll(app) }
    }

    /// Opens t2 with only its newest message open. When a conversation is
    /// already open, t1 first: the pane is rebuilt per conversation, so t2
    /// comes back with its default rows.
    private func openConversation(_ app: XCUIApplication) {
        if !rows(app).isEmpty {
            let other = app.descendants(matching: .any)
                .matching(identifier: "threadRow.you@example.com:t1").firstMatch
            XCTAssertTrue(other.waitForExistence(timeout: 10))
            other.click()
            wait("t1 replaces t2 in the pane") { rows(app).count != 4 }
        }
        let row = app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t2").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        wait("four rows, newest open") { rows(app).count == 4 && collapsedCount(app) == 3 }
        XCTAssertEqual(openIndex(app), 3)
    }

    private func stepPreviousAndNextMessageMoveTheOpenMessage(_ app: XCUIApplication) {
        openConversation(app)
        app.typeKey("p", modifierFlags: [])
        wait("p opens the third message") { openIndex(app) == 2 && collapsedCount(app) == 3 }
        app.typeKey("p", modifierFlags: [])
        wait("p again opens the second") { openIndex(app) == 1 && collapsedCount(app) == 3 }
        app.typeKey("n", modifierFlags: [])
        wait("n goes back to the third") { openIndex(app) == 2 && collapsedCount(app) == 3 }
        // The conversation list did not move: still t2.
        XCTAssertTrue(app.staticTexts.matching(identifier: "threadSubject").firstMatch.exists)
    }

    private func stepExpandAllAndCollapseAll(_ app: XCUIApplication) {
        openConversation(app)
        app.typeKey(";", modifierFlags: [])
        wait("; opens every message") { collapsedCount(app) == 0 }
        let open = rows(app)
        XCTAssertEqual(open.count, 4)
        app.typeKey(":", modifierFlags: .shift)
        wait(": closes every message") { collapsedCount(app) == 4 }
        let closed = rows(app)
        XCTAssertLessThanOrEqual((closed.map(\.height).max() ?? 0) - (closed.map(\.height).min() ?? 0), 1,
                                 "collapsed rows share one height: \(closed)")
    }
}
