import XCTest

/// With two rows checked, the bar above the list shows "2 selected", "esc to
/// clear", four icon-only buttons (archive, trash, star, read/unread) and the
/// close button, in that order, and each button acts on the checked rows.
final class SelectionBarIconsUITests: XCTestCase {
    private let order = ["archive", "trash", "star", "toggleRead"]

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        // Exposes the row's buttons (the check circle, the star) to the tree.
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

    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:\(id)").firstMatch
    }

    private func bar(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        // The count and the hint are texts: an `.any` match can resolve to a
        // wrapper with an empty label.
        let type: XCUIElement.ElementType = (id == "count" || id == "hint") ? .staticText : .any
        return app.descendants(matching: type).matching(identifier: "selectionBar.\(id)").firstMatch
    }

    private func check(_ app: XCUIApplication, _ id: String) {
        let r = row(app, id)
        XCTAssertTrue(r.waitForExistence(timeout: 10), "demo inbox should load")
        r.hover()
        let box = r.descendants(matching: .button).matching(identifier: "rowCheck").firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.click()
    }

    private func rowButton(_ app: XCUIApplication, _ id: String, _ button: String) -> XCUIElement {
        row(app, id).descendants(matching: .button).matching(identifier: button).firstMatch
    }

    /// One launch. Setup makes both selections mixed: t3 is unread and
    /// starred, t4 is read and not starred. Then look, then act (read, star,
    /// trash with undo, archive).
    func testSelectionBar() {
        let app = launch()
        let t3 = row(app, "t3")
        XCTAssertTrue(t3.waitForExistence(timeout: 10), "demo inbox should load")
        t3.hover()
        let toggle = rowButton(app, "t3", "rowAction.toggleRead")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertTrue(UITestWait.until { t3.label.hasPrefix("Unread") }, "t3 is unread")
        rowButton(app, "t3", "rowStar").click()
        XCTAssertTrue(UITestWait.until { rowButton(app, "t3", "rowStar").label == "Unstar" }, "t3 is starred")
        check(app, "t3")
        check(app, "t4")
        let steps: [(String, (XCUIApplication) -> Void)] = [
            ("The actions are icons, in order, in fixed square targets, and the bar fits", stepIconsInOrder),
            ("A mixed selection shows what the click will do", stepMixedLabels),
            ("Read/unread acts on the checked rows", stepReadActs),
            ("Star acts on the checked rows", stepStarActs),
            ("Archive acts on the checked rows", stepArchiveActs),
            ("Trash acts on the checked rows", stepTrashActs),
        ]
        for (name, step) in steps {
            XCTContext.runActivity(named: name) { _ in step(app) }
        }
    }

    private func stepIconsInOrder(_ app: XCUIApplication) {
        let count = bar(app, "count")
        XCTAssertTrue(count.waitForExistence(timeout: 5), "the bar shows once rows are checked")
        XCTAssertEqual((count.value as? String) ?? count.label, "2 selected")
        let hint = bar(app, "hint"), close = bar(app, "close")
        XCTAssertTrue(hint.exists && close.exists)
        XCTAssertLessThanOrEqual(count.frame.maxX, hint.frame.minX, "the count is not cut off by the hint")
        XCTAssertGreaterThan(count.frame.width, 40, "the count has its full width")

        let buttons = order.map { bar(app, $0) }
        for b in buttons {
            XCTAssertTrue(b.waitForExistence(timeout: 5))
            XCTAssertEqual(b.elementType, .button)
            XCTAssertEqual(b.descendants(matching: .staticText).count, 0,
                           "an icon-only button has no text: \(b.identifier)")
            XCTAssertGreaterThanOrEqual(b.frame.width, 24, "target at least 24 pt: \(b.identifier)")
            XCTAssertGreaterThanOrEqual(b.frame.height, 24)
            XCTAssertEqual(b.frame.width, b.frame.height, accuracy: 0.5, "square: \(b.identifier)")
            XCTAssertEqual(b.frame.width, buttons[0].frame.width, accuracy: 0.5, "same size for every glyph")
        }
        let xs = buttons.map(\.frame.minX)
        XCTAssertEqual(xs, xs.sorted(), "archive, trash, star, read/unread, left to right")
        for (l, r) in zip(buttons, buttons.dropFirst()) {
            XCTAssertEqual(r.frame.minX - l.frame.maxX, buttons[1].frame.minX - buttons[0].frame.maxX,
                           accuracy: 0.5, "even spacing")
        }
        XCTAssertGreaterThanOrEqual(buttons[0].frame.minX, hint.frame.maxX)
        XCTAssertLessThanOrEqual(buttons[3].frame.maxX, close.frame.minX)
        let y = buttons.map(\.frame.midY)
        XCTAssertEqual(y.max()! - y.min()!, 0, accuracy: 1, "one line")

        // The narrowest list column is 420 pt. What the bar needs: its items,
        // four 10 pt gaps, the 8 pt minimum spacer and 12 pt padding each side.
        let needed = count.frame.width + hint.frame.width
            + (buttons[3].frame.maxX - buttons[0].frame.minX) + close.frame.width + 4 * 10 + 8 + 24
        XCTAssertLessThanOrEqual(needed, 420, "the bar fits the narrowest list column")
    }

    private func stepMixedLabels(_ app: XCUIApplication) {
        XCTAssertEqual(bar(app, "archive").label, "Archive")
        XCTAssertEqual(bar(app, "trash").label, "Trash")
        XCTAssertEqual(bar(app, "star").label, "Star", "one row is not starred: the click stars")
        XCTAssertEqual(bar(app, "toggleRead").label, "Mark as read", "one row is unread: the click marks read")
    }

    private func stepReadActs(_ app: XCUIApplication) {
        let t3 = row(app, "t3"), t4 = row(app, "t4")
        XCTAssertTrue(t3.label.hasPrefix("Unread") && t4.label.hasPrefix("Read"), "\(t3.label) / \(t4.label)")
        bar(app, "toggleRead").click()
        XCTAssertTrue(UITestWait.until { t3.label.hasPrefix("Read") && t4.label.hasPrefix("Read") },
                      "both checked rows are read: \(t3.label) / \(t4.label)")
        XCTAssertEqual(bar(app, "toggleRead").label, "Mark as unread", "the icon follows the click")
    }

    private func stepStarActs(_ app: XCUIApplication) {
        XCTAssertEqual(rowButton(app, "t4", "rowStar").label, "Star")
        bar(app, "star").click()
        for id in ["t3", "t4"] {
            XCTAssertTrue(UITestWait.until { rowButton(app, id, "rowStar").label == "Unstar" }, "\(id) is starred")
        }
        XCTAssertEqual(bar(app, "star").label, "Unstar")
    }

    private func stepArchiveActs(_ app: XCUIApplication) {
        XCTAssertTrue(bar(app, "archive").waitForExistence(timeout: 5))
        bar(app, "archive").click()
        XCTAssertTrue(row(app, "t3").waitForNonExistence(timeout: 10))
        XCTAssertTrue(row(app, "t4").waitForNonExistence(timeout: 10))
        XCTAssertFalse(bar(app, "count").exists, "archiving clears the selection")
    }

    /// A second selection (t1, t2): the first one is gone after the archive.
    private func stepTrashActs(_ app: XCUIApplication) {
        check(app, "t1")
        check(app, "t2")
        XCTAssertEqual((bar(app, "count").value as? String) ?? bar(app, "count").label, "2 selected")
        bar(app, "trash").click()
        XCTAssertTrue(row(app, "t1").waitForNonExistence(timeout: 10))
        XCTAssertTrue(row(app, "t2").waitForNonExistence(timeout: 10))
        XCTAssertFalse(bar(app, "count").exists, "trashing clears the selection")
    }

    /// Undo after a Trash, by keyboard (the documented chord). Two cases in one
    /// launch, so a failure says whether the bar is the cause: first the
    /// control, a Trash from the row's own hover button (code this PR does not
    /// touch), then the same from the selection bar. No other UI test covers
    /// Trash then undo in demo mode.
    func testUndoAfterTrash() {
        let app = launch()
        let t1 = row(app, "t1")
        XCTAssertTrue(t1.waitForExistence(timeout: 10), "demo inbox should load")
        t1.hover()
        let trash = rowButton(app, "t1", "rowAction.trash")
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.click()
        XCTAssertTrue(t1.waitForNonExistence(timeout: 10), "control: the row button trashes")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(t1.waitForExistence(timeout: 10),
                      "control: Cmd-Z restores a row trashed from its own button")

        check(app, "t3")
        check(app, "t4")
        bar(app, "trash").click()
        XCTAssertTrue(row(app, "t3").waitForNonExistence(timeout: 10))
        XCTAssertTrue(row(app, "t4").waitForNonExistence(timeout: 10))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(row(app, "t3").waitForExistence(timeout: 10),
                      "bar: Cmd-Z restores t3 after Trash from the selection bar")
        XCTAssertTrue(row(app, "t4").waitForExistence(timeout: 10),
                      "bar: Cmd-Z restores t4 after Trash from the selection bar")
    }
}
