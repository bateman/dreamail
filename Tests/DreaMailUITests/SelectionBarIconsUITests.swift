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
        app.descendants(matching: .any).matching(identifier: "selectionBar.\(id)").firstMatch
    }

    private func check(_ app: XCUIApplication, _ id: String) {
        let r = row(app, id)
        XCTAssertTrue(r.waitForExistence(timeout: 10), "demo inbox should load")
        r.hover()
        let box = r.descendants(matching: .button).matching(identifier: "rowCheck").firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.click()
    }

    /// One launch: look first, then act (read, star, archive; the last one
    /// removes the rows).
    func testSelectionBar() {
        let app = launch()
        check(app, "t3")
        check(app, "t4")
        let steps: [(String, (XCUIApplication) -> Void)] = [
            ("The actions are icons, in order, between the hint and the close button", stepIconsInOrder),
            ("Each button has its accessibility label (the tooltip is a unit test)", stepLabelsAndTooltips),
            ("Read/unread acts on the checked rows", stepReadActs),
            ("Star acts on the checked rows", stepStarActs),
            ("Archive acts on the checked rows", stepArchiveActs),
        ]
        for (name, step) in steps {
            XCTContext.runActivity(named: name) { _ in step(app) }
        }
    }

    private func stepIconsInOrder(_ app: XCUIApplication) {
        let count = bar(app, "count")
        XCTAssertTrue(count.waitForExistence(timeout: 5), "the bar shows once rows are checked")
        XCTAssertEqual(count.label, "2 selected", "the count is not truncated")
        let hint = bar(app, "hint"), close = bar(app, "close")
        XCTAssertTrue(hint.exists && close.exists)
        XCTAssertLessThanOrEqual(count.frame.maxX, hint.frame.minX)

        let buttons = order.map { bar(app, $0) }
        for b in buttons {
            XCTAssertTrue(b.waitForExistence(timeout: 5))
            XCTAssertEqual(b.elementType, .button)
            XCTAssertEqual(b.descendants(matching: .staticText).count, 0,
                           "an icon-only button has no text: \(b.identifier)")
            XCTAssertLessThan(b.frame.width, 40, "icon width, not a text button")
            XCTAssertEqual(b.frame.width, buttons[0].frame.width, accuracy: 0.5)
        }
        for label in ["Archive", "Trash", "Star", "Read/Unread"] {
            XCTAssertFalse(app.buttons[label].exists, "no text button \(label) in the bar")
        }
        let xs = buttons.map(\.frame.minX)
        XCTAssertEqual(xs, xs.sorted(), "archive, trash, star, read/unread, left to right")
        XCTAssertGreaterThanOrEqual(buttons[0].frame.minX, hint.frame.maxX)
        XCTAssertLessThanOrEqual(buttons[3].frame.maxX, close.frame.minX)
        let y = buttons.map(\.frame.midY)
        XCTAssertEqual(y.max()! - y.min()!, 0, accuracy: 1, "one line")
    }

    private func stepLabelsAndTooltips(_ app: XCUIApplication) {
        let expected: [String: [String]] = [
            "archive": ["Archive"], "trash": ["Trash"],
            "star": ["Star", "Unstar"], "toggleRead": ["Mark as read", "Mark as unread"],
        ]
        for id in order {
            let b = bar(app, id)
            XCTAssertTrue(expected[id]!.contains(b.label), "\(id) label: \(b.label)")
        }
    }

    private func stepReadActs(_ app: XCUIApplication) {
        let t3 = row(app, "t3"), t4 = row(app, "t4")
        XCTAssertTrue(t3.label.hasPrefix("Read") && t4.label.hasPrefix("Read"))
        let b = bar(app, "toggleRead")
        XCTAssertEqual(b.label, "Mark as unread")
        b.click()
        XCTAssertTrue(UITestWait.until { t3.label.hasPrefix("Unread") && t4.label.hasPrefix("Unread") },
                      "both checked rows are unread: \(t3.label) / \(t4.label)")
        XCTAssertEqual(bar(app, "toggleRead").label, "Mark as read", "the icon follows the click")
    }

    private func stepStarActs(_ app: XCUIApplication) {
        let b = bar(app, "star")
        XCTAssertEqual(b.label, "Star")
        b.click()
        for id in ["t3", "t4"] {
            let star = row(app, id).descendants(matching: .button)
                .matching(identifier: "rowStar").firstMatch
            XCTAssertTrue(UITestWait.until { star.label == "Unstar" }, "\(id) is starred")
        }
        XCTAssertEqual(bar(app, "star").label, "Unstar")
    }

    private func stepArchiveActs(_ app: XCUIApplication) {
        bar(app, "archive").click()
        XCTAssertTrue(row(app, "t3").waitForNonExistence(timeout: 10))
        XCTAssertTrue(row(app, "t4").waitForNonExistence(timeout: 10))
        XCTAssertFalse(bar(app, "count").exists, "archiving clears the selection")
    }
}

private enum UITestWait {
    static func until(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
