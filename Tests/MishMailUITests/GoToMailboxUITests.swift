import XCTest

/// Regression: Gmail's `g i` (and `u`) must leave a full-window (Superhuman-style)
/// conversation and land back on the inbox list. The store already exits
/// `threadFocusMode` on every go-to; this covers the *event path* — the key
/// has to reach `MailStore.handleKey` while the conversation fills the window.
final class GoToMailboxUITests: XCTestCase {
    /// Launches the demo in full-window style and opens a conversation with
    /// the first responder parked on its selectable subject text.
    private func openFullWindowConversation()
        -> (app: XCUIApplication, row: XCUIElement, exitFocus: XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                // A saved accent must not change what this suite sees.
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "fullWindow"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()

        let demoThread = app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t1").firstMatch
        XCTAssertTrue(demoThread.waitForExistence(timeout: 10))
        demoThread.click()

        let exitFocus = app.buttons.matching(identifier: "exitFocusButton").firstMatch
        XCTAssertTrue(exitFocus.waitForExistence(timeout: 5),
                      "clicking a row in full-window style should fill the app")

        // The actual regression trigger: reading the message parks first
        // responder on the conversation's selectable (read-only) text. The key
        // monitor used to read that as "the user is typing" and stand every
        // single-key shortcut down.
        let subject = app.staticTexts.matching(identifier: "threadSubject").firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 5))
        subject.click()
        return (app, demoThread, exitFocus)
    }

    private func waitForDisappearance(_ element: XCUIElement) {
        let deadline = Date().addingTimeInterval(5)
        while element.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func testGoToInboxExitsFullWindowConversation() {
        let (app, demoThread, exitFocus) = openFullWindowConversation()

        app.typeKey("g", modifierFlags: [])
        app.typeKey("i", modifierFlags: [])

        waitForDisappearance(exitFocus)
        XCTAssertFalse(exitFocus.exists,
                       "g i must exit the full-window conversation")
        XCTAssertTrue(demoThread.waitForExistence(timeout: 5),
                      "g i must land back on the inbox list")
    }

    /// Gmail's `u` ("back to threadlist") is the default for that action;
    /// it used to be mark read / unread.
    func testUReturnsFromFullWindowConversationToTheList() {
        let (app, demoThread, exitFocus) = openFullWindowConversation()

        app.typeKey("u", modifierFlags: [])

        waitForDisappearance(exitFocus)
        XCTAssertFalse(exitFocus.exists,
                       "u must exit the full-window conversation")
        XCTAssertTrue(demoThread.waitForExistence(timeout: 5),
                      "u must land back on the list")
    }

    /// Gmail keeps its cursor on `u`: in the reading-pane style (three panes,
    /// or the narrow layout that swaps list and conversation) `u` then `j`
    /// must land on the conversation after the one just read. When `u`
    /// dropped the selection in the narrow layout, `j` started again from
    /// the top row, which is the conversation that was open.
    func testUThenJContinuesFromTheConversationJustRead() {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                // A saved accent must not change what this suite sees.
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane",
                                "-readingPaneHidden", "NO"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()

        let demoThread = app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t1").firstMatch
        XCTAssertTrue(demoThread.waitForExistence(timeout: 10))
        demoThread.click()

        let subject = app.staticTexts.matching(identifier: "threadSubject").firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 5))
        let firstSubject = text(of: subject)
        XCTAssertFalse(firstSubject.isEmpty, "the subject text must be readable")
        subject.click()

        app.typeKey("u", modifierFlags: [])
        app.typeKey("j", modifierFlags: [])

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if subject.exists, text(of: subject) != firstSubject { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(subject.waitForExistence(timeout: 2),
                      "j must open the next conversation")
        XCTAssertNotEqual(text(of: subject), firstSubject,
                          "after u, j must continue from the conversation just read")
    }

    /// A selectable SwiftUI `Text` is an NSTextField: its string is the
    /// accessibility value, and the label is often empty.
    private func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }
}
