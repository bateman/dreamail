import XCTest

/// With two rows checked, the bar above the list shows "2 selected", "esc to
/// clear" (while there is room), Gmail's actions as icon-only buttons
/// (archive or move to inbox, report spam, trash, read/unread, snooze, move
/// to, label as, then star) and the close button, in that order; the ones
/// that do not fit are under More (⋮). Each acts on the checked rows.
final class SelectionBarIconsUITests: XCTestCase {
    private let order = ["archive", "reportSpam", "trash", "toggleRead", "snooze", "moveTo", "labelAs", "star"]

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
        XCTAssertTrue(app.windows.firstMatch.appears(timeout: 10))
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
        XCTAssertTrue(r.appears(timeout: 10), "demo inbox should load")
        r.hover()
        let box = r.descendants(matching: .button).matching(identifier: "rowCheck").firstMatch
        XCTAssertTrue(box.appears(timeout: 5))
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
        XCTAssertTrue(t3.appears(timeout: 10), "demo inbox should load")
        t3.hover()
        let toggle = rowButton(app, "t3", "rowAction.toggleRead")
        XCTAssertTrue(toggle.appears(timeout: 5))
        toggle.click()
        XCTAssertTrue(UITestWait.until { t3.label.hasPrefix("Unread") }, "t3 is unread")
        rowButton(app, "t3", "rowStar").click()
        XCTAssertTrue(UITestWait.until { rowButton(app, "t3", "rowStar").label == "Unstar" }, "t3 is starred")
        check(app, "t3")
        check(app, "t4")
        let steps: [(String, (XCUIApplication) -> Void)] = [
            ("The actions are icons, in order, in fixed square targets, and the bar fits", stepIconsInOrder),
            ("A mixed selection shows what the click will do", stepMixedLabels),
            ("Snooze opens the snooze menu", stepSnoozeMenuOpens),
            ("Label as and Move to open the pickers for the checked rows", stepPickersOpen),
            ("Read/unread acts on the checked rows", stepReadActs),
            ("Star acts on the checked rows", stepStarActs),
            ("Archive acts on the checked rows", stepArchiveActs),
            ("Trash acts on the checked rows", stepTrashActs),
            ("Archived rows get Move to inbox", stepMoveToInboxActs),
        ]
        for (name, step) in steps {
            XCTContext.runActivity(named: name) { _ in step(app) }
        }
    }

    /// The bar's buttons in order: the ones shown, then (when the column is
    /// narrow) the ones under More.
    private func shown(_ app: XCUIApplication, _ ids: [String]) -> (bar: [XCUIElement], more: [String]) {
        let buttons = ids.map { bar(app, $0) }
        let visible = buttons.prefix { $0.appears(timeout: 2) }
        return (Array(visible), Array(ids.dropFirst(visible.count)))
    }

    /// Clicks the bar's button, or its item under More.
    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = bar(app, id)
        if button.appears(timeout: 2) { button.click(); return }
        let more = bar(app, "more")
        XCTAssertTrue(more.exists, "\(id) is a button or under More")
        more.click()
        let item = app.menuItems.matching(identifier: "selectionBar.more.\(id)").firstMatch
        XCTAssertTrue(item.appears(timeout: 5), id)
        item.click()
    }

    private func stepIconsInOrder(_ app: XCUIApplication) {
        let count = bar(app, "count")
        XCTAssertTrue(count.appears(timeout: 5), "the bar shows once rows are checked")
        XCTAssertEqual((count.value as? String) ?? count.label, "2 selected")
        let hint = bar(app, "hint"), close = bar(app, "close")
        XCTAssertTrue(close.exists)
        XCTAssertGreaterThan(count.frame.width, 40, "the count has its full width")

        let (visible, under) = shown(app, order)
        let more = bar(app, "more")
        XCTAssertEqual(more.exists, !under.isEmpty, "More holds exactly the actions that did not fit")
        XCTAssertGreaterThanOrEqual(visible.count, 1)
        let buttons = visible + (more.exists ? [more] : [])
        for b in buttons {
            XCTAssertEqual(b.descendants(matching: .staticText).count, 0,
                           "an icon-only button has no text: \(b.identifier)")
            XCTAssertGreaterThanOrEqual(b.frame.width, 24, "target at least 24 pt: \(b.identifier)")
            XCTAssertGreaterThanOrEqual(b.frame.height, 24)
            XCTAssertEqual(b.frame.width, b.frame.height, accuracy: 0.5, "square: \(b.identifier)")
            XCTAssertEqual(b.frame.width, buttons[0].frame.width, accuracy: 0.5, "same size for every glyph")
        }
        for b in visible where b.identifier != "selectionBar.snooze" {
            XCTAssertEqual(b.elementType, .button, b.identifier)
        }
        XCTAssertFalse(bar(app, "moveToInbox").exists, "Inbox rows: Archive, not Move to inbox")
        XCTAssertFalse(bar(app, "notSpam").exists)
        let xs = buttons.map(\.frame.minX)
        XCTAssertEqual(xs, xs.sorted(), "Gmail's order, left to right")
        let gap = buttons.count > 1 ? buttons[1].frame.minX - buttons[0].frame.maxX : 6
        for (l, r) in zip(buttons, buttons.dropFirst()) {
            XCTAssertEqual(r.frame.minX - l.frame.maxX, gap, accuracy: 0.5, "even spacing")
        }
        if hint.exists {
            XCTAssertLessThanOrEqual(count.frame.maxX, hint.frame.minX, "the count is not cut off by the hint")
        }
        XCTAssertGreaterThanOrEqual(buttons[0].frame.minX, hint.exists ? hint.frame.maxX : count.frame.maxX,
                                    "nothing covers the count or the hint")
        XCTAssertLessThanOrEqual(buttons.last!.frame.maxX, close.frame.minX)
        let y = buttons.map(\.frame.midY)
        XCTAssertEqual(y.max()! - y.min()!, 0, accuracy: 1, "one line")

        // The narrowest list column is 420 pt. What all eight buttons need
        // there, from the measured sizes: the count, the buttons, the close
        // button, three 10 pt gaps, the 8 pt minimum spacer and 12 pt padding
        // each side ("esc to clear" is the first to go when space is short).
        let side = buttons[0].frame.width
        let strip = 8 * side + 7 * gap
        let needed = count.frame.width + strip + close.frame.width + 3 * 10 + 8 + 24
        XCTAssertLessThanOrEqual(needed, 420, "every action fits the narrowest list column")
    }

    private func stepMixedLabels(_ app: XCUIApplication) {
        let expected: [(String, String)] = [
            ("archive", "Archive"), ("reportSpam", "Report spam"), ("trash", "Trash"),
            ("toggleRead", "Mark as read"), ("snooze", "Snooze"), ("moveTo", "Move to…"),
            ("labelAs", "Label as…"), ("star", "Star"),
        ]
        // Star: one row is not starred, the click stars. Read: one row is
        // unread, the click marks read. (Under More, the item says the same.)
        for (id, label) in expected where bar(app, id).exists {
            XCTAssertEqual(bar(app, id).label, label, id)
        }
    }

    private func stepSnoozeMenuOpens(_ app: XCUIApplication) {
        tap(app, "snooze")
        let pick = app.menuItems["Pick date & time…"]
        XCTAssertTrue(pick.appears(timeout: 5), "the snooze menu is open")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(UITestWait.until { !pick.exists }, "Esc closes the menu")
        XCTAssertTrue(bar(app, "count").exists, "closing the menu keeps the selection")
    }

    /// Move to and Label as open the picker for both checked rows; one
    /// click in the bulk Label as picker puts the label on both (the box
    /// goes from off to on), and clears the selection like the other bulk
    /// actions. The rows are checked again for the steps after.
    private func stepPickersOpen(_ app: XCUIApplication) {
        let search = app.descendants(matching: .any).matching(identifier: "labelPicker.search").firstMatch
        tap(app, "moveTo")
        XCTAssertTrue(search.appears(timeout: 5), "Move to opens the picker")
        XCTAssertEqual(search.placeholderValue, "Move 2 conversations to…", "for both checked rows")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(UITestWait.until { !search.exists }, "Esc closes the picker")
        XCTAssertEqual((bar(app, "count").value as? String) ?? bar(app, "count").label, "2 selected")

        tap(app, "labelAs")
        XCTAssertTrue(search.appears(timeout: 5), "Label as opens the picker")
        XCTAssertEqual(search.placeholderValue, "Label 2 conversations…", "for both checked rows")
        let travel = app.descendants(matching: .any).matching(identifier: "labelPicker.row.Travel").firstMatch
        XCTAssertTrue(travel.appears(timeout: 5))
        XCTAssertEqual(travel.value as? String, "off", "neither row has Travel")
        travel.click()
        XCTAssertTrue(UITestWait.until { (travel.value as? String) == "on" },
                      "one click puts Travel on both rows: \(String(describing: travel.value))")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(UITestWait.until { !search.exists }, "Esc closes the picker")
        XCTAssertFalse(bar(app, "count").exists, "labelling clears the selection")
        check(app, "t3")
        check(app, "t4")
        XCTAssertEqual((bar(app, "count").value as? String) ?? bar(app, "count").label, "2 selected")
    }

    private func stepReadActs(_ app: XCUIApplication) {
        let t3 = row(app, "t3"), t4 = row(app, "t4")
        XCTAssertTrue(t3.label.hasPrefix("Unread") && t4.label.hasPrefix("Read"), "\(t3.label) / \(t4.label)")
        tap(app, "toggleRead")
        XCTAssertTrue(UITestWait.until { t3.label.hasPrefix("Read") && t4.label.hasPrefix("Read") },
                      "both checked rows are read: \(t3.label) / \(t4.label)")
        XCTAssertEqual(bar(app, "toggleRead").label, "Mark as unread", "the icon follows the click")
    }

    private func stepStarActs(_ app: XCUIApplication) {
        XCTAssertEqual(rowButton(app, "t4", "rowStar").label, "Star")
        tap(app, "star")
        for id in ["t3", "t4"] {
            XCTAssertTrue(UITestWait.until { rowButton(app, id, "rowStar").label == "Unstar" }, "\(id) is starred")
        }
        if bar(app, "star").exists { XCTAssertEqual(bar(app, "star").label, "Unstar") }
    }

    private func stepArchiveActs(_ app: XCUIApplication) {
        tap(app, "archive")
        XCTAssertTrue(row(app, "t3").waitForNonExistence(timeout: 10))
        XCTAssertTrue(row(app, "t4").waitForNonExistence(timeout: 10))
        XCTAssertFalse(bar(app, "count").exists, "archiving clears the selection")
    }

    /// A second selection (t1, t2): the first one is gone after the archive.
    private func stepTrashActs(_ app: XCUIApplication) {
        check(app, "t1")
        check(app, "t2")
        XCTAssertEqual((bar(app, "count").value as? String) ?? bar(app, "count").label, "2 selected")
        tap(app, "trash")
        XCTAssertTrue(row(app, "t1").waitForNonExistence(timeout: 10))
        XCTAssertTrue(row(app, "t2").waitForNonExistence(timeout: 10))
        XCTAssertFalse(bar(app, "count").exists, "trashing clears the selection")
    }

    /// The archived t3 and t4, checked in All Mail: the archive slot is Move
    /// to inbox, and it moves both back (Gmail keeps them in All Mail).
    private func stepMoveToInboxActs(_ app: XCUIApplication) {
        app.typeKey("g", modifierFlags: [])
        app.typeKey("a", modifierFlags: [])
        check(app, "t3")
        check(app, "t4")
        XCTAssertTrue(bar(app, "moveToInbox").appears(timeout: 5), "archived rows: Move to inbox")
        XCTAssertFalse(bar(app, "archive").exists)
        XCTAssertEqual(bar(app, "moveToInbox").label, "Move to inbox")
        tap(app, "moveToInbox")
        XCTAssertTrue(UITestWait.until { !bar(app, "count").exists }, "the move clears the selection")
        for id in ["t3", "t4"] {
            row(app, id).hover()
            XCTAssertTrue(rowButton(app, id, "rowAction.archive").appears(timeout: 5),
                          "\(id) is back in the Inbox: its row offers Archive")
        }
    }
}
