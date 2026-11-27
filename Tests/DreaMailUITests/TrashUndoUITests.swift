import AppKit
import XCTest

/// Trash a conversation, then undo it: with ⌘Z, and with the toast's Undo
/// button. The row must come back in the list both times. The app's
/// breadcrumbs, printed after each step, say how far the undo got: ⌘Z seen
/// by the key monitor and with which toast, undo run, rows back after the
/// optimistic restore, toast expired.
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

    /// Trash `id` from its hover button; the row leaves and the toast shows.
    private func trash(_ app: XCUIApplication, _ id: String) {
        let r = row(app, id)
        XCTAssertTrue(r.waitForExistence(timeout: 10), "demo inbox should load")
        r.hover()
        let button = r.descendants(matching: .button).matching(identifier: "rowAction.trash").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        XCTAssertTrue(undoButton(app).waitForExistence(timeout: 3), "the undo toast shows")
        XCTAssertTrue(r.waitForNonExistence(timeout: 5), "\(id) leaves the Inbox")
    }

    func testUndoOfTrashBringsTheRowBack() {
        let app = launch()

        XCTContext.runActivity(named: "⌘Z after Trash") { _ in
            trash(app, "t1")
            XCTAssertTrue(undoButton(app).exists, "the toast is still up when ⌘Z is typed")
            app.typeKey("z", modifierFlags: .command)
            let back = row(app, "t1").waitForExistence(timeout: 10)
            report("⌘Z")
            XCTAssertTrue(back, "⌘Z brings the trashed row back")
        }

        XCTContext.runActivity(named: "Undo button after Trash") { _ in
            trash(app, "t3")
            undoButton(app).click()
            let back = row(app, "t3").waitForExistence(timeout: 10)
            report("Undo button")
            XCTAssertTrue(back, "the toast's Undo button brings the trashed row back")
        }
    }

    /// Read while the app is still alive: the app publishes its
    /// breadcrumbs on a named pasteboard (see `UITestBreadcrumbs`).
    private func report(_ step: String) {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("io.github.bateman.dreamail.uitest.breadcrumbs"))
        let crumbs = pasteboard.string(forType: .string) ?? "(no breadcrumbs on pasteboard)"
        // Event lines only: the call stacks are long and not needed here.
        let events = crumbs.split(separator: "\n").filter { !$0.hasPrefix("  ") }
            .joined(separator: "\n")
        print("TrashUndoUITests \(step) breadcrumbs:\n\(events)")
        let attachment = XCTAttachment(string: crumbs)
        attachment.name = "breadcrumbs (\(step))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
