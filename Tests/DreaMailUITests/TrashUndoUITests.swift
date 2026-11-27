import XCTest

/// Trash a conversation, then undo it: with ⌘Z, and with the toast's Undo
/// button. The row must come back in the list both times.
final class TrashUndoUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        // Exposes the row's hover buttons to the tree.
        app.launchEnvironment["DREAMAIL_UI_ROW_BUTTONS"] = "1"
        // The toast lasts 3.5 s; XCUITest needs about 4 s from the Trash click
        // to the next key (run 46046609501: the toast expired first). This
        // test is about the undo, not the toast's lifetime.
        app.launchEnvironment["DREAMAIL_UNDO_TOAST_SECONDS"] = "30"
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

    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:\(id)").firstMatch
    }

    private func undoButton(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "undoToast.undo").firstMatch
    }

    private func openConversation(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: "threadSubject").firstMatch
    }

    /// Trash `id` from its hover button; the toast shows.
    private func trash(_ app: XCUIApplication, _ id: String) {
        let r = row(app, id)
        XCTAssertTrue(r.waitForExistence(timeout: 10), "demo inbox should load")
        r.hover()
        let button = r.descendants(matching: .button).matching(identifier: "rowAction.trash").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        XCTAssertTrue(undoButton(app).waitForExistence(timeout: 3), "the undo toast shows")
    }

    /// Trashing the selected row opens the next conversation, and at the CI
    /// window width (compact layout) an open conversation replaces the list.
    /// Back to the list before looking for rows; says whether one was open.
    private func backToList(_ app: XCUIApplication) -> String {
        let subject = openConversation(app)
        guard subject.waitForExistence(timeout: 2) else { return "no conversation was open" }
        app.typeKey(.escape, modifierFlags: [])
        let closed = subject.waitForNonExistence(timeout: 5)
        return closed ? "a conversation was open, closed with Esc"
                      : "a conversation was open and Esc did not close it"
    }

    func testUndoOfTrashBringsTheRowBack() {
        let app = launch()

        XCTContext.runActivity(named: "⌘Z after Trash") { _ in
            trash(app, "t1")
            XCTAssertTrue(undoButton(app).exists, "the toast is still up when ⌘Z is typed")
            app.typeKey("z", modifierFlags: .command)
            let state = backToList(app)
            XCTAssertTrue(row(app, "t1").waitForExistence(timeout: 10),
                          "⌘Z brings the trashed row back (\(state))")
        }

        XCTContext.runActivity(named: "Undo button after Trash") { _ in
            trash(app, "t1")
            undoButton(app).click()
            let state = backToList(app)
            XCTAssertTrue(row(app, "t1").waitForExistence(timeout: 10),
                          "the toast's Undo button brings the trashed row back (\(state))")
        }
    }
}
