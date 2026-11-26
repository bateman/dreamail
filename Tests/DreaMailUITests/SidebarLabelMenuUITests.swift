import XCTest

/// The sidebar's label menu, as Gmail's (demo mailbox: `Vendors` with the
/// sublabels `Vendors/AWS` and `Vendors/Stripe`; `Research`). The demo
/// mailbox has no Gmail behind it, so the edits stay local.
final class SidebarLabelMenuUITests: XCTestCase {
    private let account = "you@example.com"

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane",
                                "-sidebar.more.expanded", "NO",
                                // Vendors open, so its sublabels are rows.
                                "-sidebar.labels.expanded.\(account)", "(Label_vendors)",
                                "-sidebar.labels.more.\(account)", "NO"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        // Sidebar starts collapsed; → reveals it (see SidebarNavUITests).
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        return app
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func label(_ gmailId: String, in app: XCUIApplication) -> XCUIElement {
        element("sidebar.label.\(account).\(gmailId)", in: app)
    }

    /// A menu item by identifier, or by title where the menu does not carry
    /// SwiftUI's identifier. The first match is the first in menu order.
    private func menuItem(_ id: String, _ title: String, in app: XCUIApplication) -> XCUIElement {
        app.menuItems.matching(NSPredicate(format: "identifier == %@ OR title == %@", id, title)).firstMatch
    }

    /// Scrolls the sidebar until `element` can be clicked: the demo has
    /// some 70 labels, so Vendors and the labels' More row start below the
    /// fold.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let sidebar = app.outlines.firstMatch
        for step in [-300.0, 300.0] {
            var tries = 0
            while !(element.exists && element.isHittable), tries < 15 {
                sidebar.scroll(byDeltaX: 0, deltaY: step)
                tries += 1
            }
            if element.exists && element.isHittable { return true }
        }
        return element.exists && element.isHittable
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    /// Clicks the ⋮ where it is drawn. XCUITest's own `click()` refuses the
    /// ⋮ as "not hittable" on the CI runners, in a way that comes and goes
    /// from one run to the next whatever the label is (a SwiftUI menu, a
    /// borderless one, an image), and scrolls the sidebar away from under
    /// the pointer, so the ⋮ vanishes. What `isHittable` would prove is
    /// checked here instead: the ⋮ lies inside the row and inside the
    /// window; and that it receives the click is proved by the callers (the
    /// menu opens, the row does not reopen). The frames go to the log.
    private func clickDots(_ dots: XCUIElement, in row: XCUIElement, app: XCUIApplication,
                           file: StaticString = #filePath, line: UInt = #line) {
        let box = dots.frame
        let window = app.windows.firstMatch.frame
        print("SidebarLabelMenu: ⋮ frame \(box), row \(row.frame), window \(window), hittable \(dots.isHittable)")
        XCTAssertTrue(window.contains(box), "the ⋮ \(box) is inside the window \(window)",
                      file: file, line: line)
        XCTAssertTrue(row.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: box.midX, y: box.midY)),
                      "the ⋮ \(box) is inside its row \(row.frame)", file: file, line: line)
        dots.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    func testMenuFromDotsAndRightClickAndDotsDoNotReopenTheLabel() {
        let app = launch()
        let research = label("Label_research", in: app)
        XCTAssertTrue(research.waitForExistence(timeout: 10))
        research.hover()
        let dots = element("sidebar.label.menu.\(account).Label_research", in: app)
        XCTAssertTrue(dots.waitForExistence(timeout: 5), "hovering a label shows its ⋮")
        clickDots(dots, in: research, app: app)
        let items: [(String, String)] = [
            ("labelMenu.color", "Label color"),
            ("labelMenu.labelList.show", "Show"),
            ("labelMenu.labelList.showIfUnread", "Show if unread"),
            ("labelMenu.labelList.hide", "Hide"),
            ("labelMenu.edit", "Edit"),
            ("labelMenu.remove", "Remove label"),
            ("labelMenu.addSublabel", "Add sublabel"),
            ("labelMenu.organize", "Organize Labels…"),
        ]
        for (id, title) in items {
            XCTAssertTrue(menuItem(id, title, in: app).waitForExistence(timeout: 5),
                          "\(title) must be in the ⋮ menu\n\(app.debugDescription)")
        }
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        research.rightClick()
        for (id, title) in items {
            XCTAssertTrue(menuItem(id, title, in: app).waitForExistence(timeout: 5),
                          "\(title) must be in the context menu")
        }
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        // On the open label, "⋮" opens the menu only: it must not also run
        // the row's tap, which would reopen the label and close the open
        // conversation. (One launch for both checks: the UI job has a time
        // budget.)
        research.click()
        let row = element("threadRow.\(account):t2", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        let subject = app.staticTexts.matching(identifier: "threadSubject").firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 5), "the conversation is open")

        research.hover()
        XCTAssertTrue(dots.waitForExistence(timeout: 5), "the open label shows its ⋮")
        clickDots(dots, in: research, app: app)
        XCTAssertTrue(menuItem("labelMenu.edit", "Edit", in: app).waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(subject.exists, "the ⋮ click did not reopen the label")
        // Gmail's "⋮" is vertical: its box is taller than wide (the old
        // horizontal ellipsis, drawn by AppKit, was wider than tall). Read
        // last, on the open label (which keeps its ⋮ without hover): reading
        // the frame before a click left the click "not hittable" in CI.
        XCTAssertTrue(dots.waitForExistence(timeout: 5), "the open label keeps its ⋮")
        XCTAssertGreaterThan(dots.frame.height, dots.frame.width, "the ⋮ is three dots stacked")
        // And no heavier than the sidebar's other glyphs: its box is not
        // taller than the row's title text plus a small margin.
        let title = research.staticTexts.firstMatch
        XCTAssertTrue(title.exists, "the label row has its title")
        XCTAssertLessThanOrEqual(dots.frame.height, title.frame.height + 4,
                                 "the ⋮ \(dots.frame) is taller than the title \(title.frame)")
    }

    func testParentColorGoesToItsSublabelsAndRemoveAsksFirst() {
        let app = launch()
        let vendors = label("Label_vendors", in: app)
        let aws = label("Label_vendors_aws", in: app)
        XCTAssertTrue(vendors.waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(vendors, in: app), "Vendors can be scrolled to")
        XCTAssertTrue(aws.waitForExistence(timeout: 5), "Vendors starts open")

        vendors.rightClick()
        let color = menuItem("labelMenu.color", "Label color", in: app)
        XCTAssertTrue(color.waitForExistence(timeout: 5))
        color.hover()
        let choose = menuItem("labelMenu.color.choose", "Choose color…", in: app)
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        let red = element("labelColor.mac.#EB5757", in: app)
        XCTAssertTrue(red.waitForExistence(timeout: 5), "the organizer's palette opens")
        red.click()
        XCTAssertTrue(waitForAbsence(red), "picking a color closes the palette")

        // The sublabel now has the same color: its palette checks it.
        XCTAssertTrue(reveal(aws, in: app))
        aws.rightClick()
        XCTAssertTrue(color.waitForExistence(timeout: 5))
        color.hover()
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        XCTAssertTrue(red.waitForExistence(timeout: 5))
        XCTAssertTrue(red.isSelected, "the parent's color went to Vendors/AWS")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForAbsence(red), "Escape closes the palette")

        // Remove asks first, and Cancel keeps the label (same launch: the UI
        // job has a time budget).
        XCTAssertTrue(reveal(vendors, in: app))
        vendors.rightClick()
        let remove = menuItem("labelMenu.remove", "Remove label", in: app)
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        let cancel = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR title == %@", "labelRemove.cancel", "Cancel")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Remove asks for confirmation")
        // Return presses the default button, Cancel.
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForAbsence(cancel))
        XCTAssertTrue(vendors.exists, "Cancel keeps the label")
        XCTAssertTrue(aws.exists, "and its sublabel")
    }

    func testHideInLabelListMovesTheLabelUnderMore() {
        let app = launch()
        let research = label("Label_research", in: app)
        XCTAssertTrue(research.waitForExistence(timeout: 10))
        let more = element("sidebar.labels.more.\(account)", in: app)
        XCTAssertFalse(more.exists, "every demo label is shown: no labels' More row")

        research.rightClick()
        let hide = menuItem("labelMenu.labelList.hide", "Hide", in: app)
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.click()

        XCTAssertTrue(waitForAbsence(research), "a hidden label leaves the list")
        XCTAssertTrue(more.waitForExistence(timeout: 5), "and goes behind the labels' More row")
        XCTAssertTrue(reveal(more, in: app), "the labels' More row can be scrolled to")
        more.click()
        XCTAssertTrue(research.waitForExistence(timeout: 5), "More shows it")
        // Closed means closed: the open label goes too.
        research.click()
        XCTAssertTrue(reveal(more, in: app))
        more.click()
        XCTAssertTrue(waitForAbsence(research), "a closed More hides the open label as well")
    }

    /// A sublabel of a listed parent is always shown nested under it, in
    /// place, whatever its own list visibility (Gmail's sidebar): hiding
    /// Vendors/Stripe through its menu sets Gmail's value but changes nothing
    /// here: no More row, no path name, the parent's name once.
    func testHiddenSublabelStaysNestedUnderItsListedParent() {
        let app = launch()
        let vendors = label("Label_vendors", in: app)
        let aws = label("Label_vendors_aws", in: app)
        let stripe = label("Label_vendors_stripe", in: app)
        let more = element("sidebar.labels.more.\(account)", in: app)
        XCTAssertTrue(reveal(vendors, in: app))
        XCTAssertTrue(aws.waitForExistence(timeout: 5))
        XCTAssertTrue(stripe.exists)
        XCTAssertFalse(more.exists, "every demo label is shown: no labels' More row")

        stripe.rightClick()
        let hide = menuItem("labelMenu.labelList.hide", "Hide", in: app)
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.click()
        // Give a wrong removal time to show before asserting the row stays.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertTrue(stripe.exists, "a hidden sublabel of a listed parent stays listed")
        XCTAssertFalse(more.exists, "and needs no More row")
        // Inside Vendors' subtree: after its sibling, indented like it.
        XCTAssertLessThan(vendors.frame.minY, aws.frame.minY)
        XCTAssertLessThan(aws.frame.minY, stripe.frame.minY, "in sibling order, under AWS")
        XCTAssertEqual(stripe.frame.minX, aws.frame.minX, accuracy: 1, "indented like its siblings")
        // Short names, no path: the demo has labels named "Starred / keep",
        // so look at the sublabels' own rows, not at every text.
        let sidebar = app.outlines.firstMatch
        XCTAssertTrue(stripe.staticTexts["Stripe"].exists, "the sublabel shows its short name")
        XCTAssertTrue(aws.staticTexts["AWS"].exists)
        XCTAssertFalse(sidebar.staticTexts["Vendors/Stripe"].exists, "no row is named with a path")
        XCTAssertFalse(sidebar.staticTexts["Vendors/AWS"].exists)
        XCTAssertEqual(sidebar.staticTexts.matching(NSPredicate(
            format: "label == 'Vendors' OR identifier == 'Vendors'")).count, 1,
                       "the parent's name appears once")
    }
}
